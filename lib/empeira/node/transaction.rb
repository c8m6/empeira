# frozen_string_literal: true

module Empeira
  module Node
    # Inventory writes are brief; native guest execution owns no Empeira lock.
    module Transaction
      private

      def mutate(availability: true, destructive: false)
        @build_info.require_compatible!(context.configuration.dig('requirements', 'empeira'))
        @store.with_operation(destructive: destructive) do
          load_state
          check_runtime!(availability: availability)
          result = yield
          @store.operation.check!
          result
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Naming/PredicateMethod -- Reconcile each matching immutable instance in its own operation without retaining a workspace lock.
      def reconcile_instances(state, provider)
        state.fetch('nodes', {}).values.select { |record| record['provider'] == provider }.map do |previous|
          mutate(availability: false) do
            raise Infrastructure::Cancelled, 'Workspace was recreated during reconciliation' unless
              !state['generation'] || @state['generation'] == state['generation']

            record = @nodes[previous.fetch('hostname')]
            unless record && Inventory.instance(record) == Inventory.instance(previous) && !record['deleting']
              next false
            end

            @store.operation.attach(record)
            yield record
          end
        end.any?
      end

      def reserve_instance(hostname)
        @store.operation.resource("node/#{hostname.downcase}") do
          @store.with_lock do
            load_state
            @store.operation.check!(@state)
            yield
          end
        end
      end

      # Pin shared DNS and native lease preparation against control-plane replacement/teardown.
      def reservation_phase(hostname)
        @store.operation.resource('infrastructure-phase') do
          @store.operation.resource("node/#{hostname.downcase}") do
            load_state
            @store.operation.check!(@state)
            yield
          end
        end
      end

      def instance_phase(record, &)
        @store.operation.resource("node/#{record.fetch('hostname')}", &)
      end

      def guest_configuration(record)
        @store.operation.resource("guest-configuration/#{Inventory.instance(record)}") do
          @store.operation.refresh(@state)
          yield
        end
      end

      def claim_lifecycle(name)
        reserve_instance(name) do
          record = @nodes.fetch(name.downcase) { raise Providers::NotFound, 'Node does not exist in this workspace' }
          @store.operation.attach(record)
          record['lifecycle_revision'] = SecureRandom.hex(16)
          save
          @store.operation.attach(record, lifecycle: true)
          record
        end
      end

      def record_completion(record, result)
        record['last_puppet_exit'] = result.exit_status
        @store.operation&.force('nodes', record.fetch('hostname'), 'last_puppet_exit')
        save
      end

      def cancel_lifecycle(record)
        @store.with_lock do
          current = @store.load
          current.fetch('nodes').fetch(record.fetch('hostname'))['lifecycle_revision'] = SecureRandom.hex(16)
          @store.write(current)
        end
      end
    end
  end
end
