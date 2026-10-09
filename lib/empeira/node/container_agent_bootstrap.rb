# frozen_string_literal: true

module Empeira
  module Node
    # Runs the selected agent installation through container guest I/O.
    module ContainerAgentBootstrap
      private

      # rubocop:disable-next Metrics/AbcSize -- The ordered guest transaction spans packages, APT and agent installation.
      def apply_agent_bootstrap(resource, record)
        execute = ->(arguments) { @runtime.service_exec(resource, arguments, timeout: 300) }
        requirements = package_requirements(record, agent_required: true)
        @bootstrap_proxy.start(@state, requirements, source: record.dig('definition', 'ip'))
        family = PackageBootstrap::FAMILIES.fetch(record.fetch('os'))
        configuration = family == 'debian' ? AptConfiguration : RpmConfiguration
        configuration.new(os: record.fetch('os'), execute: execute).preserve do
          packages = package_bootstrap(resource, record)
          packages.run(proxy_url: @bootstrap_proxy.url) if packages.required?
          install_agent(resource, record, requirements, execute)
        end
        ContainerBootstrap.new(runtime: @runtime).apply(resource: resource,
                                                        bootstrap: Bootstrap.new(provider: 'container'))
        PackageSources.verify!(execute: execute)
      end

      def install_agent(resource, _record, requirements, execute)
        installer = AgentInstaller.build(context: context, runtime: @runtime, requirements: requirements,
                                         execute: execute, copy: guest_copy(resource, execute), progress: @progress)
        installer.install(proxy_url: @bootstrap_proxy.url)
      end

      def guest_copy(resource, execute)
        lambda do |source, destination, mode|
          @runtime.copy_to(resource, source, destination)
          raise Error, 'Cannot set agent file permissions' unless
            execute.call(['chmod', mode, destination]).success?
        end
      end
    end
  end
end
