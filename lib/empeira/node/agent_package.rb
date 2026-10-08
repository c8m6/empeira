# frozen_string_literal: true

module Empeira
  module Node
    # Verified HTTPS package acquisition followed by native package-manager installation.
    class AgentPackage < AgentRepository
      PACKAGE_PATH = '/var/tmp/empeira-agent-package'

      def initialize(os:, rpm_options: [], **arguments)
        super(**arguments)
        @os = os
        @rpm_options = rpm_options
      end

      def install(proxy_url:)
        self.class.credentials
        prepared = true
        install_proxy(proxy_url)
        download_verified(@source, package_path)
        install_package
        verify_version!
      ensure
        if prepared
          execute!(['rm', '-f', '--', package_path, CURL_CONFIG_PATH,
                    debian? ? PackageProxy::APT_PATH : PackageProxy::DNF_PATH], 'agent package cleanup')
        end
      end

      private

      def proxy_family
        debian? ? 'debian' : 'redhat'
      end

      def package_path
        "#{PACKAGE_PATH}.#{debian? ? 'deb' : 'rpm'}"
      end

      def debian?
        PackageBootstrap::FAMILIES.fetch(@os) == 'debian'
      end

      def install_package
        if debian?
          execute!(['apt-get', *@package_proxy.arguments, '-o', 'Acquire::http::AllowRedirect=false',
                    '-o', 'Acquire::https::AllowRedirect=false',
                    'install', '-y', '--', package_path],
                   'APT agent package installation')
        else
          execute!(['dnf', *@package_proxy.arguments, '--setopt=localpkg_gpgcheck=1', *@rpm_options,
                    'install', '--assumeyes', '--', package_path], 'DNF agent package installation')
        end
      end

      def verify_version!
        arguments = if debian?
                      ['dpkg-query', '-W', '-f=${Version}', @package]
                    else
                      # rubocop:disable-next Style/FormatStringToken -- RPM queryformat is not Ruby formatting.
                      ['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}', @package]
                    end
        result = @execute.call(arguments)
        return if result.success? && result.stdout.strip == @version

        raise Error, 'Installed agent package version differs from agent.version; Puppet was not run'
      end
    end
  end
end
