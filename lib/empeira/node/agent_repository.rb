# frozen_string_literal: true

require 'uri'

module Empeira
  module Node
    # Shared guest file delivery and diagnostics; the base installer uses signed APT.
    # The DNF subclass retains the same installation and credential semantics.
    # rubocop:disable-next Metrics/ClassLength -- One temporary APT transaction owns source, auth and diagnosis.
    class AgentRepository
      AUTH_PATH = '/etc/apt/auth.conf.d/00-empeira-agent.conf'
      APT_PROXY_PATH = PackageProxy::APT_PATH
      CURL_CONFIG_PATH = '/var/tmp/empeira-agent-curl.conf'
      SOURCE_PATH = '/etc/apt/sources.list.d/empeira-agent.list'
      KEY_PATH = '/etc/apt/keyrings/empeira-agent.gpg'

      def self.credentials
        username = ENV.fetch('EMPEIRA_AGENT_REPO_USERNAME', nil)
        password = ENV.fetch('EMPEIRA_AGENT_REPO_PASSWORD', nil)
        return if username.nil? && password.nil?

        values = [username, password]
        return values if values.all? { |value| value.is_a?(String) && value.match?(/\A[^\s#]+\z/) }

        raise ConfigurationError, 'Set both nonempty EMPEIRA_AGENT_REPO_USERNAME and ' \
                                  'EMPEIRA_AGENT_REPO_PASSWORD for agent repository authentication'
      end

      def initialize(source:, package:, version:, execute:, copy:)
        @source = source
        @package = package
        @version = version
        @execute = execute
        @copy = copy
      end

      def install(proxy_url:)
        @release_package = nil
        credentials = self.class.credentials
        prepared = true
        install_proxy(proxy_url)
        install_source
        install_auth(credentials) if credentials
        apt!('update')
        apt!('install', "#{@package}=#{@version}#{@source.fetch('suffix')}")
        verify_version!
      ensure
        begin
          remove_release_package if @release_package
        ensure
          cleanup_temporary_files(credentials) if prepared
        end
      end

      private

      def install_source
        if (release = @source['release'] || (@source if @source.key?('sha256')))
          install_release(release)
        else
          execute!(['mkdir', '-p', '/etc/apt/keyrings'], 'keyring directory preparation')
          download_verified(@source.fetch('key'), KEY_PATH)
          source = "deb [signed-by=#{KEY_PATH}] #{@source.fetch('url')} #{@source.fetch('suite')} " \
                   "#{@source.fetch('component')}\n"
          copy_text(source, SOURCE_PATH, mode: '0644')
        end
      end

      def install_release(release)
        path = '/var/tmp/empeira-agent-release.deb'
        download_verified(release, path)
        metadata = @execute.call(['dpkg-deb', '--field', path, 'Package'])
        name = metadata.stdout.strip
        unless metadata.success? && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9+.-]*\z/)
          raise Error, 'Agent release package has invalid package metadata'
        end

        require_absent_release!(name)
        @release_package = name
        execute!(['dpkg', '-i', path], 'release package installation')
      ensure
        execute!(['rm', '-f', path], 'release package cleanup') if path
      end

      def remove_release_package
        return unless installed_release_packages.include?(@release_package)

        execute!(release_removal_arguments, 'release package cleanup')
      end

      def require_absent_release!(name)
        return unless installed_release_packages.include?(name)

        raise Error, 'Agent release package already exists; refusing to replace or remove it. Puppet was not run'
      end

      def installed_release_packages
        result = @execute.call(release_inventory_arguments)
        unless result.success?
          raise Error, 'Cannot verify release-package ownership; node retained and Puppet was not run'
        end

        result.stdout.lines.map(&:strip)
      end

      def release_inventory_arguments
        ['dpkg-query', '-W', '-f=${Package}\n']
      end

      def release_removal_arguments
        ['dpkg', '--purge', '--', @release_package]
      end

      def download_verified(artifact, path)
        configure_download(artifact)
        execute!(['curl', '--fail', '--silent', '--show-error', '--proto', '=https', '--max-redirs', '0',
                  '--connect-timeout', '10', '--max-time', '120', '--config', CURL_CONFIG_PATH,
                  '--output', path, artifact.fetch('url')], 'repository artifact download')
        result = @execute.call(['sha256sum', path])
        raise Error, 'Agent repository artifact checksum mismatch' unless
          result.success? && result.stdout.split.first == artifact.fetch('sha256')
      end

      def configure_download(artifact)
        credentials = self.class.credentials
        content = "proxy = #{@proxy_url.dump}\n"
        if credentials && URI(artifact.fetch('url')).host == URI(@source.fetch('url')).host
          content += "user = #{"#{credentials.first}:#{credentials.last}".dump}\n"
        end
        copy_text(content, CURL_CONFIG_PATH, mode: '0600')
      end

      def install_auth(credentials)
        uri = URI(@source.fetch('url'))
        path = @source.key?('sha256') ? '/' : uri.path
        path = "#{path}/" unless path.empty? || path.end_with?('/')
        endpoint = "https://#{uri.host}#{":#{uri.port}" unless uri.port == 443}#{path}"
        content = "machine #{endpoint}\nlogin #{credentials.first}\npassword #{credentials.last}\n"
        copy_text(content, auth_path, mode: '0600')
      end

      def auth_path
        AUTH_PATH
      end

      def install_proxy(url)
        @proxy_url = url
        @package_proxy = PackageProxy.new(family: proxy_family, execute: @execute, copy: @copy)
        @package_proxy.prepare(url)
      end

      def proxy_family
        'debian'
      end

      def copy_text(content, destination, mode:)
        PackageProxy.copy_text(@copy, content, destination, mode: mode)
      end

      def cleanup_temporary_files(credentials)
        paths = [APT_PROXY_PATH, CURL_CONFIG_PATH, SOURCE_PATH, KEY_PATH]
        paths.unshift(auth_path) if credentials
        execute!(['rm', '-f', '--', *paths], 'agent repository credential cleanup')
      end

      def apt!(operation, package = nil)
        options = ['-o', 'Acquire::http::AllowRedirect=false', '-o', 'Acquire::https::AllowRedirect=false',
                   '-o', 'APT::Update::Error-Mode=any']
        arguments = ['apt-get', *@package_proxy.arguments, *options, operation, '-y']
        arguments.push('--', package) if package
        execute!(arguments, "APT #{operation}")
      end

      def verify_version!
        result = @execute.call(['dpkg-query', '-W', '-f=${Version}', @package])
        expected = "#{@version}#{@source.fetch('suffix')}"
        return if result.success? && result.stdout.strip == expected

        raise Error, 'Installed agent version differs from the requested package version'
      end

      def execute!(arguments, operation)
        result = @execute.call(arguments)
        return result if result.success?

        diagnostic = redacted_diagnostic(result)
        guidance = failure_guidance("#{result.stderr}\n#{result.stdout}", operation)
        raise Error, "#{guidance} (exit=#{result.exit_status}). #{diagnostic}; node retained and Puppet was not run"
      end

      def redacted_diagnostic(result)
        diagnostic = PackageProxy.redact("#{result.stderr}\n#{result.stdout}", @proxy_url)
        Execution::Diagnostics.clean(diagnostic)
      end

      def failure_guidance(diagnostic, operation)
        case diagnostic
        when /\b(?:403|407)\b.*from proxy|Proxy Authentication Required/i
          'Bootstrap proxy access denied; check managed bootstrap authentication and destination policy.'
        when /\b401\b|Unauthorized/i
          'Agent repository authentication failed. Set both EMPEIRA_AGENT_REPO_USERNAME and ' \
          'EMPEIRA_AGENT_REPO_PASSWORD.'
        when /\b403\b|Forbidden/i then 'Agent repository access denied; check permissions.'
        when /NO_PUBKEY|signatures couldn.t be verified|not signed|GPG check FAILED|public key.*not installed/i
          'Agent repository signature verification failed; check its signing key.'
        when /Version .* was not found|No match for argument|Unable to find a match/i then unavailable_versions
        when /\b404\b|Not Found/i then 'Agent repository or package version is unavailable.'
        else "Agent #{operation} failed"
        end
      end

      def unavailable_versions
        versions = @execute.call(['apt-cache', 'madison', @package])
        available = versions.stdout.lines.first(20).filter_map { |line| line.split('|')[1]&.strip }
                            .grep(/\A[0-9][a-zA-Z0-9.+:~-]*\z/).uniq.first(8)
        listing = available.empty? ? 'none reported' : available.join(', ')
        "Requested agent package version is unavailable. Available versions: #{listing}"
      end
    end
  end
end
