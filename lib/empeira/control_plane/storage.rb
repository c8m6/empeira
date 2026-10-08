# frozen_string_literal: true

module Empeira
  module ControlPlane
    class Storage
      def initialize(runtime:, plan:, inventory:, persist:)
        @runtime = runtime
        @plan = plan
        @inventory = inventory
        @persist = persist
        @changed = false
      end

      def prepare
        @plan.files.credentials(existing: database_recorded?) if @plan.database?
        @plan.volumes.each_value { |definition| ensure_volume(definition) }
        @changed
      end

      def database_recorded?
        definition = @plan.volume('postgres-data')
        @inventory.fetch('volumes').key?(definition.key) || !@runtime.inspect_volume(definition).nil?
      end

      def ensure_volume(definition)
        expected = @inventory.fetch('volumes').dig(definition.key, 'id')
        resource = @runtime.inspect_volume(definition, expected_id: expected)
        if !resource && expected
          raise Error, "Retained volume #{definition.key} is missing; restore it before starting services"
        end

        resource ||= create_volume(definition)
        @inventory.fetch('volumes')[definition.key] = { 'id' => resource.fetch('id') }
        @persist.call
      end

      def create_volume(definition)
        @inventory.fetch('volumes')[definition.key] = { 'id' => nil }
        @persist.call
        @changed = true
        @runtime.create_volume(definition)
      end
    end
  end
end
