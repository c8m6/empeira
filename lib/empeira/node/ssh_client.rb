# frozen_string_literal: true

require 'shellwords'

module Empeira
  module Node
    class SSHClient
      def initialize(runner:, credentials:, user:, proxy_command: nil)
        @runner = runner
        @credentials = credentials
        @user = user
        @proxy_command = proxy_command
      end

      def options(record)
        @credentials.verify!
        unless record.fetch('ssh_host', '127.0.0.1') == '127.0.0.1' &&
               record['ssh_port'].is_a?(Integer) && record['ssh_port'].between?(1, 65_535)
          raise Error, 'Managed SSH endpoint is missing or inconsistent; destroy and recreate the node'
        end

        ['-F', File::NULL, '-i', @credentials.key_path.to_s, '-p', record.fetch('ssh_port').to_s,
         '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'PasswordAuthentication=no',
         '-o', 'StrictHostKeyChecking=accept-new', '-o', known_hosts_option,
         '-o', "GlobalKnownHostsFile=#{File::NULL}", '-o', 'ConnectTimeout=5', '-o', 'ForwardAgent=no',
         '-o', 'ClearAllForwardings=yes', *proxy_options]
      end

      def proxy_options
        return [] unless @proxy_command

        ['-o', "ProxyCommand=#{Shellwords.join(@proxy_command).gsub('%', '%%')}"]
      end

      def known_hosts_option
        path = @credentials.known_hosts.to_s.gsub(/["\\]/) { |character| "\\#{character}" }.gsub('%', '%%')
        "UserKnownHostsFile=\"#{path}\""
      end

      def destination
        "#{@user}@127.0.0.1"
      end

      def run(record, arguments, timeout: 15)
        @runner.run('ssh', arguments: [*options(record), destination, Shellwords.join(arguments)], timeout: timeout)
      end

      def session(record)
        unless run(record, ['true']).success?
          raise Error,
                "SSH daemon or managed authentication is unavailable for #{record.fetch('hostname')}; " \
                'inspect node shell/logs'
        end

        @runner.stream('ssh', arguments: ['-tt', *options(record), destination])
      end
    end
  end
end
