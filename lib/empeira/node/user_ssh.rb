# frozen_string_literal: true

require 'etc'

module Empeira
  module Node
    # Provider defaults select authentication; endpoint and host-key policy remain managed.
    class UserSSH
      def initialize(runner:, credentials:, proxy_command: nil, default_user: nil, managed_identity: false,
                     home: Dir.home)
        @runner = runner
        @credentials = credentials
        @proxy_command = proxy_command
        @default_user = default_user
        @managed_identity = managed_identity
        @identity = SSHIdentity.new(home: home)
      end

      def session(record, user: nil, identity: nil)
        @credentials.prepare_hosts
        username = username_for(user)
        transport = SSHClient.new(credentials: @credentials, proxy_command: @proxy_command)
        arguments = ['-tt', '-l', username, *options(record, transport), *authentication_options(identity)]
        @runner.stream('ssh', arguments: [*arguments, record.fetch('hostname')])
      end

      def username_for(user)
        username = user || @default_user || Etc.getpwuid(Process.uid).name
        unless username.is_a?(String) && username.match?(/\A[a-zA-Z0-9_.@-]+\z/)
          raise ConfigurationError, 'SSH user must be a valid login name'
        end

        username
      end

      def authentication_options(identity)
        return identity ? ['-i', @identity.resolve(identity)] : [] unless @managed_identity

        @credentials.verify! unless identity
        key = identity ? @identity.resolve(identity) : @credentials.key_path.to_s
        ['-i', key, '-o', 'IdentitiesOnly=yes', '-o', 'PasswordAuthentication=no',
         '-o', 'KbdInteractiveAuthentication=no', '-o', 'ForwardAgent=no']
      end

      def options(record, transport)
        port = record['ssh_port']
        unless record.fetch('ssh_host', '127.0.0.1') == '127.0.0.1' && port.is_a?(Integer) && port.between?(1, 65_535)
          raise Error, 'Managed SSH endpoint is missing or inconsistent'
        end

        proxy = @proxy_command ? transport.proxy_options : ['-o', 'ProxyCommand=none']
        ['-p', port.to_s, '-o', 'HostName=127.0.0.1', '-o', "HostKeyAlias=#{record.fetch('hostname')}",
         '-o', transport.known_hosts_option, '-o', "GlobalKnownHostsFile=#{File::NULL}",
         '-o', 'StrictHostKeyChecking=accept-new', '-o', 'CanonicalizeHostname=no',
         '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ClearAllForwardings=yes',
         *proxy, '-o', 'ProxyJump=none']
      end
    end
  end
end
