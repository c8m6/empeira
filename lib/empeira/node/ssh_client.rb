# frozen_string_literal: true

require 'shellwords'

module Empeira
  module Node
    class SSHClient
      def initialize(credentials:, proxy_command: nil)
        @credentials = credentials
        @proxy_command = proxy_command
      end

      def proxy_options
        return [] unless @proxy_command

        ['-o', "ProxyCommand=#{Shellwords.join(@proxy_command).gsub('%', '%%')}"]
      end

      def known_hosts_option
        path = @credentials.known_hosts.to_s.gsub(/["\\]/) { |character| "\\#{character}" }.gsub('%', '%%')
        "UserKnownHostsFile=\"#{path}\""
      end
    end
  end
end
