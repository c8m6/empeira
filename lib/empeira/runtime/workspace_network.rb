# frozen_string_literal: true

module Empeira
  module Runtime
    module WorkspaceNetwork
      # This privileged, short-lived operation runs in the engine's Linux host
      # namespace, including Docker Desktop's VM. It does not share host files,
      # sockets or PID namespaces, and cannot select arbitrary firewall rules.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Verify ownership before this narrow host-namespace transaction.
      def reconcile_workspace_bridge(definition:, expected_id:, image:, action:)
        return unless name == 'docker'

        resource = inspect_network(identifier: definition.backend_name)
        definition.verify_ownership!(resource, expected_id: expected_id)
        raise Providers::OwnershipError, 'Workspace network is missing' unless resource

        definition.verify_isolation!(resource)
        details = network_details(resource.id)
        bridge = "ep#{context.workspace.id[0, 10]}"
        unless details.dig('Options', 'com.docker.network.bridge.name') == bridge &&
               details.fetch('IPAM').fetch('Config').any? { |item| item['Subnet'] == definition.allocation }
          raise Providers::OwnershipError, 'Workspace bridge or subnet conflicts with recorded allocation'
        end

        helper = Empeira::Services::Definition.new(key: "bridge-#{SecureRandom.hex(16)}", workspace: context.workspace)
        service_command(['run', '--rm', '--pull=never', '--name', helper.name, '--network', 'host',
                         '--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--cap-add', 'NET_RAW',
                         '--security-opt', 'no-new-privileges', '--read-only',
                         '--tmpfs', '/run:rw,noexec,nosuid,size=1m', *label_arguments(helper),
                         '--entrypoint', '/usr/local/libexec/empeira-bridge', image,
                         action, bridge, definition.allocation, resource.id],
                        operation: 'workspace bridge attachment', timeout: action == 'check' ? 3 : 30)
      ensure
        if helper && (remaining = inspect_service(helper))
          service_command(['rm', '--force', remaining.fetch('id')], operation: 'bridge helper cleanup')
        end
      end

      def detach_egress(definition, resource)
        service_command(['network', 'disconnect', definition.backend_name, resource.fetch('id')],
                        operation: 'gateway uplink detachment')
      end

      # Only the target's network namespace is shared. No host namespace, Docker
      # socket, target filesystem or persistent NET_ADMIN capability is exposed.
      # rubocop:disable-next Metrics/AbcSize -- Bound the privilege and cleanup of a single namespace operation.
      def configure_workspace_route(resource, gateway:, image:)
        labels = resource.fetch('labels')
        unless labels['io.empeira.managed-by'] == 'empeira' && labels['io.empeira.workspace'] == context.workspace.id
          raise Providers::OwnershipError, 'Cannot configure routing on a foreign container'
        end

        helper = Empeira::Services::Definition.new(key: "route-#{SecureRandom.hex(16)}", workspace: context.workspace)
        arguments = ['run', '--rm', '--pull=never', '--name', helper.name,
                     '--network', "container:#{resource.fetch('id')}", '--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN',
                     '--security-opt', 'no-new-privileges', '--read-only',
                     '--tmpfs', '/run:rw,noexec,nosuid,size=1m', *label_arguments(helper),
                     '--entrypoint', Network::Gateway::EXECUTABLE, image, 'route', gateway]
        service_command(arguments, operation: 'workspace default routing')
      ensure
        if helper && (remaining = inspect_service(helper))
          service_command(['rm', '--force', remaining.fetch('id')], operation: 'route helper cleanup')
        end
      end
    end

    Container.include(WorkspaceNetwork)
  end
end
