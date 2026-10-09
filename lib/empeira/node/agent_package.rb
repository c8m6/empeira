# frozen_string_literal: true

# rubocop:disable Style/FormatStringToken -- RPM and DNF use their native query-format tokens.

module Empeira
  module Node
    # Installs one host-acquired artifact through the guest's native manager and original base sources.
    class AgentPackage
      PACKAGE_PATH = '/var/tmp/empeira-agent-package'

      def initialize(target:, package:, artifact:, execute:, copy:, rpm_options: [])
        @target = target
        @package = package
        @artifact = artifact
        @execute = execute
        @copy = copy
        @rpm_options = rpm_options
        @paths = []
      end

      def install(proxy_url:)
        @proxy_url = proxy_url
        @package_proxy = PackageProxy.new(family: @target.family, execute: @execute, copy: @copy)
        @paths << @package_proxy.path
        @package_proxy.prepare(proxy_url)
        @paths << package_path
        @copy.call(@artifact.path, package_path, '0600')
        install_keys if @target.format == 'rpm'
        install_package
        verify_version!
      ensure
        cleanup
      end

      private

      def cleanup
        remove_introduced_keys if @original_keys
      ensure
        execute!(['rm', '-f', '--', *@paths], 'local agent artifact cleanup') unless @paths.empty?
      end

      def package_path
        "#{PACKAGE_PATH}.#{@target.format}"
      end

      def install_package
        if @target.format == 'deb'
          options = ['-o', 'Acquire::http::AllowRedirect=false', '-o', 'Acquire::https::AllowRedirect=false',
                     '-o', 'APT::Update::Error-Mode=any']
          execute!(['apt-get', *@package_proxy.arguments, *options, 'update'], 'base dependency metadata acquisition')
          execute!(['apt-get', *@package_proxy.arguments, *options, 'install', '-y', '--', package_path],
                   'local APT agent installation (dependencies must be available in the original base sources)')
        else
          verification = @artifact.metadata.fetch('verify_signatures') ? 1 : 0
          execute!(['dnf', *@package_proxy.arguments, "--setopt=localpkg_gpgcheck=#{verification}", *@rpm_options,
                    'install', '--assumeyes', '--', package_path],
                   'local DNF agent installation (dependencies must be available in the original base sources)')
        end
      end

      def install_keys
        @original_keys = signing_keys
        @artifact.metadata.fetch('public_keys').each_with_index do |encoded, index|
          path = "/var/tmp/empeira-agent-signing-key-#{index}"
          @paths << path
          PackageProxy.copy_text(@copy, Base64.strict_decode64(encoded), path)
          execute!(['rpmkeys', '--import', path], 'temporary agent signing key import')
        end
      end

      def signing_keys
        result = execute!(['rpm', '-qa', '--qf', "%{NAME}-%{VERSION}-%{RELEASE}\n", 'gpg-pubkey'],
                          'agent signing key ownership verification')
        result.stdout.lines.map(&:strip).sort.tap do |keys|
          raise Error, 'Cannot validate RPM signing key identity; Puppet was not run' unless
            keys.all? { |key| key.match?(/\Agpg-pubkey-[a-f0-9]+-[a-f0-9]+\z/) }
        end
      end

      def remove_introduced_keys
        (signing_keys - @original_keys).each do |key|
          execute!(['rpm', '-e', '--', key], 'temporary signing key cleanup')
        end
        raise Error, 'Cannot verify agent signing key cleanup; Puppet was not run' unless signing_keys == @original_keys
      end

      def installed_identity
        command = identity_command
        result = execute!(command, 'installed agent identity verification')
        name, version, architecture = result.stdout.strip.split('|')
        version = version.delete_prefix('0:') if @target.format == 'rpm' && version
        [name, version, architecture]
      end

      def identity_command
        if @target.format == 'deb'
          ['dpkg-query', '-W', '-f=${Package}|${Version}|${Architecture}', @package]
        else
          ['rpm', '-q', '--qf', '%{NAME}|%{EPOCHNUM}:%{VERSION}-%{RELEASE}|%{ARCH}', @package]
        end
      end

      def verify_version!
        name, version, architecture = installed_identity
        return if name == @package && version == @artifact.metadata.fetch('version') &&
                  architecture == @artifact.metadata.fetch('architecture')

        raise Error, 'Installed agent package identity differs from the resolved artifact; Puppet was not run'
      end

      def execute!(arguments, operation)
        result = @execute.call(arguments)
        return result if result.success?

        text = PackageProxy.redact("#{result.stderr}\n#{result.stdout}", @proxy_url)
        diagnostic = Execution::Diagnostics.native(result.with(stderr: text, stdout: ''),
                                                   operation: "Agent #{operation}", tool: arguments.first)
        raise Error, "Agent #{operation} failed; node retained and Puppet was not run\n#{diagnostic}", cause: nil
      end
    end
  end
end

# rubocop:enable Style/FormatStringToken
