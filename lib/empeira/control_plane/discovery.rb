# frozen_string_literal: true

module Empeira
  module ControlPlane
    class Discovery
      def initialize(plan:, runtime:, state:)
        @plan = plan
        @runtime = runtime
        @state = state
      end

      def refresh(services: nil, node_resources: nil, reload_proxy: true, force_proxy_reload: false)
        nodes = @state.fetch('nodes', {})
        definitions = node_definitions(nodes)
        expected = nodes.select { |_, record| record['provider'] == 'container' }
                        .transform_values { |record| record['id'] }
        resources = inspect(definitions, expected, services, node_resources)
        resources.merge!(lease_resources(nodes))
        @plan.files.hosts(resources, @plan.network)
        refresh_proxy(resources, nodes, reload: reload_proxy, force: force_proxy_reload)
      end

      private

      def node_definitions(nodes)
        nodes.select { |_, record| record['provider'] == 'container' }.transform_values do |record|
          Node::Definition.new(hostname: record.fetch('hostname'), workspace: @plan.context.workspace)
        end
      end

      def refresh_proxy(resources, nodes, reload:, force:)
        changed = @plan.files.proxy_clients(resources, @plan.network, nodes: nodes)
        resource = resources['proxy']
        reload_proxy(resource, changed: changed || force) if reload && resource&.fetch('state') == 'running'
        changed
      end

      def reload_proxy(resource, changed:)
        checkpoint = { 'id' => resource.fetch('id'), 'fingerprint' => @plan.files.proxy_reload_digest }
        plane = @state.fetch('control_plane')
        return if !changed && plane['proxy_reload'] == checkpoint

        @runtime.reload_service(resource)
        plane['proxy_reload'] = checkpoint
      end

      def lease_resources(nodes)
        nodes.filter_map do |name, record|
          address = record.dig('peer', 'ip') || record.dig('definition', 'ip')
          [name, { 'networks' => { @plan.network => { 'IPAddress' => address } } }] if address
        end.to_h
      end

      def inspect_nodes(definitions, expected)
        definitions.empty? ? {} : @runtime.inspect_services(definitions, expected_ids: expected)
      end

      def inspect(definitions, expected, services, node_resources)
        if services
          nodes = node_resources || inspect_nodes(definitions, expected)
          return services.merge(nodes.compact)
        end
        @plan.browser_enabled = @state.dig('control_plane', 'services')&.key?('browser')
        expected.merge!(@state.fetch('control_plane').fetch('services').transform_values { |record| record['id'] })
        @runtime.inspect_services(@plan.definitions.merge(definitions), expected_ids: expected).compact
      end
    end
  end
end
