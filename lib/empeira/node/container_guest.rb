# frozen_string_literal: true

module Empeira
  module Node
    module ContainerGuest
      private

      def reconcile_guest(resource, record)
        fact_changed = reconcile_provider_fact(resource, record)
        environment_changed = prepare_guest_environment(resource, record)
        reconcile_command_mocks(resource, record) || environment_changed || fact_changed
      end

      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates owned guest state and reports changes.
      def reconcile_provider_fact(resource, record)
        digest = ExternalFact.fingerprint('container')
        return false if record['empeira_fact'] == digest

        ContainerBootstrap.new(runtime: @runtime).reconcile(resource: resource,
                                                            bootstrap: Bootstrap.new(provider: 'container'))
        record['empeira_fact'] = digest
        save
        true
      end

      def prepare_guest_environment(resource, record)
        proxy_changed = reconcile_runtime_proxy(resource, record)
        reconcile_interactive_tools(resource, record) || proxy_changed
      end

      def reconcile_interactive_tools(resource, record)
        InteractiveTools.new(record: record, persist: method(:save),
                             execute: ->(arguments) { @runtime.service_exec(resource, arguments) }).reconcile
      end

      def reconcile_runtime_proxy(resource, record)
        RuntimeProxy.new(context: context, record: record, persist: method(:save),
                         execute: ->(arguments) { @runtime.service_exec(resource, arguments) }).reconcile
      end
    end
  end
end
