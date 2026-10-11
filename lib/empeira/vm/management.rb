# frozen_string_literal: true

module Empeira
  module VM
    # Numeric-root execution over a private VirtIO port, independent of guest login policy.
    module Management
      VERSION = 2
      SLOTS = 8
      CHANNEL = 'org.empeira.management.0'
      DEVICE = "/dev/virtio-ports/#{CHANNEL}".freeze
      DIRECTORY = '/etc/empeira/management'
      UNIT = '/etc/systemd/system/empeira-management.service'
      AGENT = '/usr/local/libexec/empeira-management-agent'
      SHELL_RC = '/usr/local/libexec/empeira-management-shell-rc'
      SETUP = '/usr/local/libexec/empeira-management-setup'
      UPLOADS = '/run/empeira-management'

      def self.validate!(record)
        return if record['management_layout'] == VERSION

        raise Error, 'Incompatible VM management layout; use node destroy to remove the owned VM, then recreate it'
      end

      # rubocop:disable-next Metrics/AbcSize -- Seed the service, adapter and one-time regular account together.
      def self.files(record, system_key:)
        validate!(record)
        raise Error, 'VM system SSH requires a public key' if system_key.to_s.empty?

        setup = File.read(resource('setup.sh')).sub('@SYSTEM_SETUP@', File.read(resource('system_account.sh')) +
                                                                   File.read(resource('system_home.sh')))
        { AGENT => [File.read(resource('guest_agent.py')), '0755'], UNIT => [service(record), '0644'],
          SETUP => [setup, '0755'], SHELL_RC => [File.read(resource('shell_rc.sh')), '0644'],
          "#{DIRECTORY}/system_authorized_keys" => ["#{system_key}\n", '0644'] }.map do |path, entry|
          { 'path' => path, 'permissions' => entry[1], 'owner' => 'root:root', 'content' => entry[0] }
        end
      end

      # rubocop:disable-next Metrics/MethodLength -- Keep the complete private service policy in one literal.
      def self.service(record)
        token = record.fetch('peer').fetch('token')
        raise Error, 'Invalid VM instance identity' unless token.match?(/\A[0-9a-f]{32}\z/)

        <<~UNIT
          # Managed by Empeira; no SSH, PAM, NSS login or sudo dependency.
          [Unit]
          Description=Empeira private VirtIO management
          After=systemd-udev-trigger.service
          [Service]
          Type=simple
          User=0
          Group=0
          UMask=0077
          RuntimeDirectory=empeira-management
          RuntimeDirectoryMode=0700
          ExecStart=/usr/local/libexec/empeira-management-python #{AGENT} #{DEVICE} #{token} #{extra_devices.join(' ')}
          StandardOutput=null
          Restart=on-failure
          RestartSec=2
          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      def self.resource(name)
        Pathname(__dir__).join('../../../resources/nodes/management', name)
      end

      def self.extra_devices
        (1...SLOTS).map { |slot| "/dev/virtio-ports/org.empeira.management.#{slot}" }
      end
    end
  end
end
