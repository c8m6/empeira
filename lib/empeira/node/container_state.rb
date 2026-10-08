# frozen_string_literal: true

module Empeira
  module Node
    module ContainerState
      def list
        load_state
        records = container_records
        return [] if records.empty?

        check_runtime!
        definitions = records.transform_values { |record| definition(record) }
        resources = @runtime.inspect_services(definitions, expected_ids: records.transform_values do |record|
          record['id']
        end)
        records.map { |name, record| inventory_row(record, resources[name]) }
      end

      def inspect_resource(name:)
        load_state
        record = @nodes[name.downcase]
        return unless record

        check_runtime!
        resource = observed(record)
        return unless resource

        state = record['provisioned'] && resource['state'] == 'running' ? :running : :stopped
        Providers::Resource.new(name: record.fetch('hostname'), owner: context.workspace.id, state: state)
      end

      private

      def inventory_row(record, resource)
        verify_network!(resource, record) if resource
        record.slice('hostname', 'provider', 'runtime', 'os', 'version', 'last_puppet_exit').merge(
          'state' => state_of(record, resource)
        )
      end

      def container_records
        @nodes.select { |_, record| record['provider'] == 'container' }
      end

      def lifecycle_result(name, state, changed:)
        resource = Providers::Resource.new(name: name, owner: context.workspace.id, state: state)
        Providers::Result.new(resource: resource, changed: changed)
      end

      def mutate
        @build_info.require_compatible!(context.configuration.dig('requirements', 'empeira'))
        @store.with_lock do
          load_state
          check_runtime!
          yield
        end
      end

      def load_state
        @state = @store.load
        @nodes = @state&.fetch('nodes', {}) || {}
      end

      def save
        @state['nodes'] = @nodes
        @store.write(@state)
      end

      def check_runtime!
        if @state && @state.fetch('runtime') != context.container_engine
          raise Error, 'Node runtime differs from workspace ownership; restore runtime.container_engine'
        end

        @runtime.check_available!
      end

      def fetch(name)
        @nodes.fetch(name.downcase) { raise Providers::NotFound, 'Node does not exist in this workspace' }
      end

      def definition(record)
        Definition.new(hostname: record.fetch('hostname'), workspace: context.workspace,
                       **record.fetch('definition').except('hostname').transform_keys(&:to_sym))
      end

      def observed(record)
        resource = @runtime.inspect_service(definition(record), expected_id: record['id'])
        verify_network!(resource, record) if resource
        resource
      end

      def verify_network!(resource, record)
        network = Network::Definition.new(workspace: context.workspace, policy: Network::Policy.new).backend_name
        return if resource.fetch('networks').keys == [network] && SSHEndpoint.valid?(resource, record)

        raise Providers::OwnershipError, 'Node has unexpected network membership or published ports'
      end

      def running(record)
        resource = observed(record)
        raise Error, 'Node is missing; destroy its reservation before recreating it' unless resource
        unless resource['state'] == 'running'
          raise Error,
                "Node #{record.fetch('hostname')} is stopped; " \
                "start it with: empeira node start #{record.fetch('hostname')}"
        end

        resource
      end

      def state_of(record, resource)
        return 'missing' unless resource
        return 'incomplete' unless record['provisioned']
        return 'stale' unless resource.dig('labels', 'io.empeira.definition') == definition(record).fingerprint
        return 'stale' unless Image.new(config: context.configuration, request: request_for(record),
                                        architecture: record['architecture']).reference == record['image']

        resource['state'] == 'exited' ? 'stopped' : resource['state']
      rescue ConfigurationError
        'stale'
      end

      def request_for(record)
        RunRequest.new(**record.slice('hostname', 'provider', 'os', 'version', 'memory', 'cpus')
          .transform_keys(&:to_sym))
      end
    end
  end
end
