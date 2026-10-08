# frozen_string_literal: true

module Empeira
  module Node
    # DNF's native per-repository authentication stays in a temporary 0600 file.
    class DnfAgentRepository < AgentRepository
      REPO_PATH = '/etc/yum.repos.d/empeira-agent.repo'
      KEY_PATH = '/var/tmp/empeira-agent-rpm-key.gpg'
      CONFIG_PATH = PackageProxy::DNF_PATH

      def initialize(rpm_options: [], **arguments)
        super(**arguments)
        @rpm_options = rpm_options
      end

      def install(proxy_url:)
        @release_package = nil
        @proxy_url = proxy_url
        credentials = self.class.credentials
        if credentials && @source.key?('sha256')
          raise ConfigurationError, 'Authenticated DNF release-package repositories are unsupported; ' \
                                    'configure agent.install.dnf with a scoped signed source'
        end
        prepared = true
        install_proxy(proxy_url)
        prepare_source(credentials)
        dnf!('makecache', '--refresh')
        dnf!('install', '--assumeyes', "#{@package}-#{expected_version}")
        verify_version!
      ensure
        cleanup_source if prepared
      end

      private

      def proxy_family
        'redhat'
      end

      def prepare_source(credentials)
        return install_release if @source.key?('sha256')

        download_verified(@source.fetch('key'), KEY_PATH)
        copy_text(repo_content(credentials), REPO_PATH, mode: '0600')
      end

      def install_release
        path = '/var/tmp/empeira-agent-release.rpm'
        download_verified(@source, path)
        # rubocop:disable-next Style/FormatStringToken -- RPM queryformat is not Ruby formatting.
        metadata = @execute.call(['rpm', '-qp', '--qf', '%{NAME}', path])
        name = metadata.stdout.strip
        unless metadata.success? && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9+.-]*\z/)
          raise Error, 'Agent release package has invalid package metadata'
        end

        require_absent_release!(name)
        @release_package = name
        execute!(['rpm', '-i', path], 'release package installation')
      end

      def cleanup_source
        remove_release_package if @release_package
      ensure
        execute!(['rm', '-f', '--', REPO_PATH, KEY_PATH, CONFIG_PATH, CURL_CONFIG_PATH,
                  '/var/tmp/empeira-agent-release.rpm'], 'DNF agent repository cleanup')
      end

      def release_inventory_arguments
        # rubocop:disable-next Style/FormatStringToken -- RPM queryformat is not Ruby formatting.
        ['rpm', '-qa', '--qf', "%{NAME}\n"]
      end

      def release_removal_arguments
        ['rpm', '-e', '--', @release_package]
      end

      def repo_content(credentials)
        lines = ['[empeira-agent]', 'name=Empeira temporary agent source', "baseurl=#{@source.fetch('url')}",
                 'enabled=1', 'gpgcheck=1', "gpgkey=file://#{KEY_PATH}", 'sslverify=1',
                 'skip_if_unavailable=0', "includepkgs=#{@package}"]
        lines.push("username=#{credentials.first}", "password=#{credentials.last}") if credentials
        "#{lines.join("\n")}\n"
      end

      def dnf!(*arguments)
        execute!(['dnf', "--config=#{CONFIG_PATH}", *@rpm_options, *arguments], 'DNF agent installation')
      end

      def expected_version
        "#{@version}#{@source.fetch('suffix')}"
      end

      def verify_version!
        # rubocop:disable-next Style/FormatStringToken -- This is rpm queryformat syntax.
        result = @execute.call(['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}', @package])
        return if result.success? && result.stdout.strip == expected_version

        raise Error, 'Installed agent version differs from the requested package version'
      end

      def unavailable_versions
        result = @execute.call(['dnf', "--config=#{CONFIG_PATH}", *@rpm_options, 'list', '--showduplicates', @package])
        available = result.stdout.lines.filter_map { |line| line.split[1] if line.start_with?("#{@package}.") }
                          .grep(/\A[0-9][a-zA-Z0-9.+:~-]*\z/).uniq.first(8)
        listing = available.empty? ? 'none reported' : available.join(', ')
        "Requested agent package version is unavailable. Available versions: #{listing}"
      end
    end
  end
end
