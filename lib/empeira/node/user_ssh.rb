# frozen_string_literal: true

require 'etc'

module Empeira
  module Node
    # Authentication belongs to the developer and guest; only transport is managed.
    class UserSSH
      def initialize(runner:, credentials:, proxy_command: nil)
        @runner = runner
        @credentials = credentials
        @proxy_command = proxy_command
      end

      def session(record, user: nil, identity: nil)
        @credentials.prepare_hosts
        username = user || Etc.getpwuid(Process.uid).name
        unless username.is_a?(String) && username.match?(/\A[a-zA-Z0-9_.@-]+\z/)
          raise ConfigurationError, 'SSH user must be a valid login name'
        end

        transport = SSHClient.new(runner: @runner, credentials: @credentials, user: username,
                                  proxy_command: @proxy_command)
        arguments = ['-tt', '-l', username, *options(record, transport)]
        arguments.push('-i', File.expand_path(identity)) if identity
        @runner.stream('ssh', arguments: [*arguments, record.fetch('hostname')])
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
