# frozen_string_literal: true

require 'digest'
require 'ipaddr'

module Empeira
  module VM
    # Versioned guest management layout. Missing versions retain the original SSH transport.
    module Management
      VERSION = 1
      ADDRESS = '10.0.2.15'
      PORT = 22_222
      DIRECTORY = '/etc/empeira/management'
      CONFIG = "#{DIRECTORY}/sshd_config".freeze
      UNIT = '/etc/systemd/system/empeira-management-ssh.service'
      CHECK = '/usr/local/libexec/empeira-management-check'
      SETUP = '/usr/local/libexec/empeira-management-setup'

      def self.separate?(record) = record.key?('ssh_layout')
      def self.home(_record) = '/home/empeira'

      # rubocop:disable-next Metrics/AbcSize -- Assemble the complete versioned cloud-init boundary in one place.
      def self.files(record, public_key)
        config = configuration(record)
        unit = service
        checker = File.read(resource('check.sh'))
                      .sub('@CONFIG_SHA@', Digest::SHA256.hexdigest(config))
                      .sub('@UNIT_SHA@', Digest::SHA256.hexdigest(unit))
                      .sub('@AUTHORIZED_SHA@', Digest::SHA256.hexdigest("#{public_key}\n"))
        setup = File.read(resource('setup.sh')).sub('@SELINUX_SETUP@', File.read(resource('selinux.sh')))
        { CONFIG => [config, '0644'], UNIT => [unit, '0644'], CHECK => [checker, '0755'],
          SETUP => [setup, '0755'],
          "#{DIRECTORY}/empeira_management.cil" => [selinux_policy, '0644'],
          "#{DIRECTORY}/authorized_keys" => ["#{public_key}\n", '0644'] }.map do |path, (content, mode)|
          { 'path' => path, 'permissions' => mode, 'owner' => 'root:root', 'content' => content }
        end
      end

      def self.selinux_policy
        File.read(resource('policy.cil')).gsub('@PORT@', PORT.to_s).gsub('@DIRECTORY@', DIRECTORY)
      end

      # rubocop:disable-next Metrics/MethodLength -- Keep the complete dedicated daemon policy in one literal.
      def self.configuration(record)
        address = IPAddr.new(record.fetch('peer').fetch('ip'))
        raise Error, 'VM system SSH target must be an isolated IPv4 peer' unless address.ipv4? && address.private?

        <<~CONFIG
          # Managed by Empeira; independent of the system SSH daemon.
          Port #{PORT}
          ListenAddress #{ADDRESS}
          AddressFamily inet
          HostKey #{DIRECTORY}/ssh_host_ed25519_key
          PidFile /run/empeira-management-ssh/sshd.pid
          AuthorizedKeysFile #{DIRECTORY}/authorized_keys
          AuthorizedKeysCommand none
          TrustedUserCAKeys none
          AllowUsers empeira
          AuthenticationMethods publickey
          PubkeyAuthentication yes
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          PermitRootLogin no
          UsePAM yes
          StrictModes yes
          AllowAgentForwarding no
          X11Forwarding no
          PermitUserRC no
          PermitUserEnvironment no
          AllowTcpForwarding local
          PermitOpen #{address}:*
          AllowStreamLocalForwarding no
          GatewayPorts no
          Subsystem sftp internal-sftp
        CONFIG
      end

      def self.service
        <<~UNIT
          # Managed by Empeira. No dependency on ssh.service or sshd.service.
          [Unit]
          Description=Empeira private management SSH
          After=network.target
          [Service]
          Type=simple
          RuntimeDirectory=empeira-management-ssh
          RuntimeDirectoryMode=0700
          # OpenSSH's compiled privilege-separation directory must survive system SSH shutdown.
          TemporaryFileSystem=/run /var/empty /run/sshd:ro /var/empty/sshd:ro
          BindReadOnlyPaths=/run/systemd -/run/dbus -/run/user
          BindPaths=/run/empeira-management-ssh
          ExecStartPre=/bin/sh -c 'if test -e /sys/fs/selinux/enforce; then exec restorecon -R /run/empeira-management-ssh; fi'
          ExecStartPre=/usr/sbin/sshd -t -f #{CONFIG}
          ExecStart=/usr/sbin/sshd -D -e -f #{CONFIG}
          Restart=on-failure
          RestartSec=2
          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      def self.resource(name)
        Pathname(__dir__).join('../../../resources/nodes/management', name)
      end
    end
  end
end
