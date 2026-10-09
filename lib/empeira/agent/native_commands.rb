# frozen_string_literal: true

module Empeira
  module Agent
    # Shared helper execution, scoped authentication, artifact delivery and release ownership.
    module NativeCommands
      private

      def download_artifact(artifact, filename)
        path = File.join(@directory, filename)
        @download.fetch(artifact.fetch('url'), path, sha256: artifact['sha256'])
        path
      end

      def install_auth
        credentials = @authentication.credentials
        return unless credentials

        uri = URI(@source.fetch('url'))
        endpoint = "https://#{uri.host}#{":#{uri.port}" unless uri.port == 443}"
        content = "machine #{endpoint}\nlogin #{quote_auth(credentials.first)}\n" \
                  "password #{quote_auth(credentials.last)}\n"
        copy_text(content, self.class::AUTH_PATH, mode: '0600')
      end

      def quote_auth(value)
        escaped = value.gsub(/["\\]/) { |character| "\\#{character}" }
        "\"#{escaped}\""
      end

      def native!(arguments, operation)
        @authentication.attempt do
          install_auth
          execute!(arguments, operation)
        end
      end

      def execute!(arguments, operation)
        result = @execute.call(arguments)
        return result if result.success?

        text = @authentication.redact("#{result.stderr}\n#{result.stdout}")
        case text
        when /\b407\b|Proxy Authentication Required/i then raise Error,
                                                                 'Host helper proxy authentication failed (HTTP 407)'
        when /\b401\b|Unauthorized/i then raise Agent::AuthenticationRequired,
                                                'Agent repository requires authentication'
        when /\b403\b|Forbidden/i then raise Error, 'Agent repository access denied (HTTP 403)'
        end
        diagnostic = Execution::Diagnostics.clean(text)
        raise Error, "Agent #{operation} failed (exit=#{result.exit_status}): #{diagnostic}", cause: nil
      end

      def copy_text(content, destination, mode:)
        Node::PackageProxy.copy_text(@copy, content, destination, mode: mode)
      end

      def require_absent_release!(name)
        Configuration::AgentSchema.package_token!(name, 'Agent release package name')
        return unless installed_release_packages.include?(name)

        raise Error, 'Agent release package already exists in the helper; refusing to replace or remove it'
      end

      def installed_release_packages
        execute!(release_inventory_arguments, 'release-package ownership verification').stdout.lines.map(&:strip)
      end

      def release_inventory_arguments
        ['dpkg-query', '-W', '-f=${Package}\n']
      end

      def release_removal_arguments
        ['dpkg', '--purge', '--', @release_package]
      end

      def remove_release_package
        return unless installed_release_packages.include?(@release_package)

        execute!(release_removal_arguments, 'release package cleanup')
        raise Error, 'Cannot verify agent helper release package cleanup' if
          installed_release_packages.include?(@release_package)
      end
    end
  end
end
