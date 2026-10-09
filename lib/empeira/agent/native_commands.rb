# frozen_string_literal: true

module Empeira
  module Agent
    # Shared helper execution, scoped authentication, artifact delivery and release ownership.
    module NativeCommands
      private

      def download_artifact(artifact, filename)
        path = File.join(@directory, filename)
        operation = filename == 'signing-key' ? 'Download agent signing key' : 'Download agent release package'
        @download.fetch(artifact.fetch('url'), path, sha256: artifact['sha256'], operation: operation)
        path
      end

      def install_auth
        credentials = @authentication.credentials
        return unless credentials

        uri = URI(@source.fetch('url'))
        endpoint = "https://#{uri.host}#{":#{uri.port}" unless uri.port == 443}"
        # APT's netrc parser treats quotes and backslashes as literal credential bytes.
        content = "machine #{endpoint}\nlogin #{credentials.first}\npassword #{credentials.last}\n"
        copy_text(content, self.class::AUTH_PATH, mode: '0600')
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
        diagnostic = Execution::Diagnostics.native(result.with(stderr: text, stdout: ''),
                                                   operation: "Agent #{operation}", tool: arguments.first)
        case text
        when /407\s+Proxy Authentication Required|(?:HTTP|Status code|HTTP code)\s*:?\s*407\b/i
          raise Error, "Host helper proxy authentication failed\n#{diagnostic}", cause: nil
        when /401\s+Unauthorized|(?:HTTP|Status code|HTTP code)\s*:?\s*401\b/i
          raise Agent::AuthenticationRequired, diagnostic, cause: nil
        when /403\s+Forbidden|(?:HTTP|Status code|HTTP code)\s*:?\s*403\b/i
          raise Error, "Agent repository access denied\n#{diagnostic}", cause: nil
        end
        raise Error, "Agent #{operation} failed\n#{diagnostic}", cause: nil
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
