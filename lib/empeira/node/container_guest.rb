# frozen_string_literal: true

module Empeira
  module Node
    module ContainerGuest
      private

      def reconcile_guest(resource, record)
        proxy_changed = reconcile_runtime_proxy(resource, record)
        reconcile_command_mocks(resource, record) || proxy_changed
      end

      def reconcile_runtime_proxy(resource, record)
        RuntimeProxy.new(context: context, record: record, persist: method(:save),
                         execute: ->(arguments) { @runtime.service_exec(resource, arguments) }).reconcile
      end
    end
  end
end
