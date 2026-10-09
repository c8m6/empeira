# frozen_string_literal: true

require 'tempfile'
require 'uri'

module Empeira
  module Node
    # One private guest configuration for APT/DNF proxy credentials; never put them in argv.
    class PackageProxy
      APT_PATH = '/etc/apt/apt.conf.d/00-empeira-agent-proxy'
      DNF_PATH = '/var/tmp/empeira-agent-dnf.conf'

      def initialize(family:, execute:, copy:)
        @family = family
        @execute = execute
        @copy = copy
      end

      def self.copy_text(copy, content, destination, mode: '0600')
        Tempfile.create('empeira-agent-') do |file|
          file.chmod(0o600)
          file.write(content)
          file.flush
          copy.call(file.path, destination, mode)
        end
      end

      def self.redact(diagnostic, proxy_url)
        values = URI(proxy_url).userinfo.to_s.split(':') if proxy_url
        values = [*values, ENV.fetch('EMPEIRA_AGENT_REPO_USERNAME', nil), ENV.fetch('EMPEIRA_AGENT_REPO_PASSWORD', nil)]
        values.compact.reject(&:empty?).sort_by { |value| -value.length }
              .reduce(diagnostic) { |text, value| text.gsub(value, '[REDACTED]') }
      end

      def prepare(url)
        content = if @family == 'debian'
                    "Acquire::http::Proxy #{url.dump};\nAcquire::https::Proxy #{url.dump};\n"
                  else
                    dnf_configuration(url)
                  end
        self.class.copy_text(@copy, content, path)
      end

      def arguments
        @family == 'debian' ? ['-c', path] : ["--config=#{path}"]
      end

      def path
        @family == 'debian' ? APT_PATH : DNF_PATH
      end

      def cleanup
        result = @execute.call(['rm', '-f', '--', path])
        return if result.success?

        diagnostic = Execution::Diagnostics.command(result, operation: 'Temporary package proxy cleanup', tool: 'rm')
        raise Error, "Cannot remove temporary package proxy configuration; Puppet was not run\n#{diagnostic}",
              cause: nil
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Preserve native sections while enforcing private, verified bootstrap settings.
      def dnf_configuration(url)
        lines = original_dnf_lines
        main = lines.index { |line| line.strip == '[main]' }
        raise Error, 'Original DNF configuration has no main section; Puppet was not run' unless main

        finish = ((main + 1)...lines.size).find { |index| lines[index].lstrip.start_with?('[') } || lines.size
        settings = lines[(main + 1)...finish].grep_v(/\A\s*(?:proxy(?:_[a-z_]+)?|gpgcheck|sslverify|logfilelevel)\s*=/i)
        lines[main] = "[main]\n"
        lines[(main + 1)...finish] = [*dnf_proxy_settings(url), *settings]
        lines.join
      end

      def dnf_proxy_settings(url)
        endpoint = URI(url)
        username = endpoint.user
        password = endpoint.password
        endpoint.user = nil
        endpoint.password = nil
        settings = ["proxy=#{endpoint}\n", "gpgcheck=1\n", "sslverify=1\n", "logfilelevel=0\n"]
        if username || password
          settings.push("proxy_username=#{URI::DEFAULT_PARSER.unescape(username.to_s)}\n",
                        "proxy_password=#{URI::DEFAULT_PARSER.unescape(password.to_s)}\n",
                        "proxy_auth_method=basic\n")
        end
        settings
      end

      def original_dnf_lines
        result = @execute.call(['cat', '/etc/dnf/dnf.conf'])
        unless result.success?
          diagnostic = Execution::Diagnostics.command(result, operation: 'Original DNF configuration', tool: 'cat')
          raise Error, "Cannot read original DNF configuration; Puppet was not run\n#{diagnostic}", cause: nil
        end

        result.stdout.lines
      end
    end
  end
end
