# frozen_string_literal: true

require 'tmpdir'

module Empeira
  module Runtime
    # Shared service contract for Docker and Podman. No shell or Compose orchestration.
    module Services
      include ServiceInspection
      include ServiceImages
      include ImageMetadata
      include RecipeBuild
      include RegistryDiagnostics

      def inspect_service(definition, expected_id: nil)
        inspect_owned('container', definition, expected_id: expected_id)
      end

      def inspect_volume(definition, expected_id: nil)
        inspect_owned('volume', definition, expected_id: expected_id)
      end

      def create_volume(definition)
        service_command(['volume', 'create', *label_arguments(definition),
                         '--label', "io.empeira.volume-id=#{SecureRandom.uuid}",
                         definition.name], operation: 'volume creation')
        inspect_volume(definition)
      end

      def remove_volume(definition, expected_id:)
        resource = inspect_volume(definition, expected_id: expected_id)
        return unless resource

        service_command(['volume', 'rm', definition.name], operation: 'persistent volume removal')
        raise Providers::ExecutionError, 'Volume removal could not be verified' if inspect_volume(definition)
      end

      def create_service(definition)
        service_command(create_service_arguments(definition), operation: "#{definition.key} creation")
        inspect_service(definition)
      end

      def start_service(resource)
        service_command(['start', resource.fetch('id')], operation: 'service start')
      end

      # rubocop:disable-next Naming/PredicateMethod -- This mutation returns whether it changed infrastructure.
      def remove_service(definition, expected_id: nil)
        resource = inspect_service(definition, expected_id: expected_id)
        return false unless resource

        service_command(['stop', '--time', '20', resource.fetch('id')], operation: 'service stop', timeout: 40)
        volumes = ['--volumes']
        service_command(['rm', *volumes, resource.fetch('id')], operation: 'service removal')
        raise Providers::ExecutionError, 'Service removal could not be verified' if inspect_service(definition)

        true
      end

      def reload_service(resource, signal: 'HUP')
        service_command(['kill', '--signal', signal, resource.fetch('id')], operation: 'service reload')
      end

      def stop_service(resource)
        service_command(['stop', '--time', '20', resource.fetch('id')], operation: 'node stop', timeout: 40)
      end

      def ssh_proxy_command(resource)
        helper = Pathname(__dir__).join('../../../resources/nodes/ssh/proxy.rb').realpath
        [RbConfig.ruby, helper.to_s, name, resource.fetch('id')]
      end

      def stream_service(resource, arguments, interactive: false, logs: false)
        command = if logs
                    ['logs', '--follow', resource.fetch('id')]
                  else
                    ['exec', *(interactive ? ['--interactive'] : []),
                     *(interactive && $stdin.tty? && $stdout.tty? ? ['--tty'] : []), resource.fetch('id'), *arguments]
                  end
        runner.stream(name, arguments: command)
      end

      def service_exec(resource, arguments, timeout: 15, on_stdout: nil)
        options = on_stdout ? { on_stdout: on_stdout } : {}
        runner.run(name, arguments: ['exec', resource.fetch('id'), *arguments], timeout: timeout, **options)
      end

      def copy_from(resource, source, destination)
        service_command(['cp', "#{resource.fetch('id')}:#{source}", destination.to_s], operation: 'certificate export')
      end

      def copy_to(resource, source, destination)
        service_command(['cp', source.to_s, "#{resource.fetch('id')}:#{destination}"],
                        operation: 'service configuration')
      end

      def attach_egress(definition, resource)
        service_command(['network', 'connect', definition.backend_name, resource.fetch('id')],
                        operation: 'proxy egress attachment')
      end

      private

      def service_command(arguments, operation:, timeout: 30)
        result = runner.run(name, arguments: arguments, timeout: timeout)
        return result if result.success?

        raise Providers::ExecutionError,
              "#{name} #{operation} failed; run empeira status\n" \
              "#{Execution::Diagnostics.native(result, operation: operation, tool: name)}", cause: nil
      end

      def create_service_arguments(definition)
        ServiceArguments.new(definition).build
      end
    end

    Container.include(Services)
  end
end
