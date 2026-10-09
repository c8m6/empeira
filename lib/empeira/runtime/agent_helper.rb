# frozen_string_literal: true

module Empeira
  module Runtime
    # Reuses helper ownership and observed default-network verification, without host bind mounts.
    module AgentHelper
      def with_agent_helper(image:)
        identity = Empeira::Services::Definition.new(key: "agent-#{SecureRandom.hex(16)}", workspace: context.workspace)
        update_command(agent_helper_arguments(identity, image), operation: 'agent helper creation')
        resource = inspect_service(identity)
        raise Providers::ExecutionError, 'Agent helper creation could not be verified' unless resource

        update_command(['start', resource.fetch('id')], operation: 'agent helper start')
        verify_helper_network!(identity, resource.fetch('id'))
        yield resource
      ensure
        remove_update_helper(identity, resource&.fetch('id')) if identity
      end

      private

      def agent_helper_arguments(identity, image)
        ['create', '--name', identity.name, '--network', update_helper_network,
         '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
         *%w[CHOWN DAC_OVERRIDE FOWNER SETUID SETGID].flat_map { |capability| ['--cap-add', capability] },
         *label_arguments(identity),
         *UpdateHelper::PROXY_VARIABLES.select { |key| ENV.key?(key) }.flat_map { |key| ['--env', key] },
         '--entrypoint', 'sleep', image, 'infinity']
      end
    end

    Container.include(AgentHelper)
  end
end
