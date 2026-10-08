# frozen_string_literal: true

module Empeira
  module ControlPlane
    class Discovery
      def initialize(plan:, runtime:, state:)
        @plan = plan
        @runtime = runtime
        @state = state
      end

      def refresh(services: nil, reload_proxy: true)
        nodes = @state.fetch('nodes', {})
        definitions = node_definitions(nodes)
        expected = nodes.select { |_, record| record['provider'] == 'container' }
                        .transform_values { |record| record['id'] }
        resources = inspect(definitions, expected, services)
        resources.merge!(lease_resources(nodes))
        @plan.files.hosts(resources, @plan.network)
        refresh_proxy(resources, nodes, reload: reload_proxy)
      end

      private

      def node_definitions(nodes)
        nodes.select { |_, record| record['provider'] == 'container' }.transform_values do |record|
          Node::Definition.new(hostname: record.fetch('hostname'), workspace: @plan.context.workspace)
        end
      end

      def refresh_proxy(resources, nodes, reload:)
        @plan.files.proxy_clients(resources, @plan.network, nodes: nodes)
        @runtime.reload_service(resources['proxy']) if reload && resources.dig('proxy', 'state') == 'running'
      end

      def lease_resources(nodes)
        nodes.filter_map do |name, record|
          address = record.dig('peer', 'ip') || record.dig('definition', 'ip')
          [name, { 'networks' => { @plan.network => { 'IPAddress' => address } } }] if address
        end.to_h
      end

      def inspect(definitions, expected, services)
        if services
          nodes = definitions.empty? ? {} : @runtime.inspect_services(definitions, expected_ids: expected)
          return services.merge(nodes.compact)
        end
        @plan.browser_enabled = @state.dig('control_plane', 'services')&.key?('browser')
        expected.merge!(@state.fetch('control_plane').fetch('services').transform_values { |record| record['id'] })
        @runtime.inspect_services(@plan.definitions.merge(definitions), expected_ids: expected).compact
      end
    end
  end
end
