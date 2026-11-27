# frozen_string_literal: true

require 'securerandom'

module Empeira
  module Infrastructure
    class Cancelled < Error; end

    # A view of one infrastructure incarnation, never a lock over a running workload.
    # rubocop:disable-next Metrics/ClassLength -- Keep incarnation checks and three-way inventory publication in one transaction boundary.
    class Operation
      REMOVED = Object.new.freeze

      def initialize(store:, state:, destructive: false, generation: nil)
        @store = store
        @generation = state&.fetch('generation', nil)
        if generation && @generation != generation
          raise Cancelled, 'Operation cancelled: its workspace was destroyed or recreated'
        end

        @destructive = destructive
        @snapshots = {}.compare_by_identity
        @forced = []
        @phase_depth = 0
      end

      attr_reader :generation

      def node_phase(&)
        raise StateError, 'Node operation has no instance identity' unless @name

        resource("node/#{@name}", &)
      end

      def helper(identity, id)
        state = @store.load
        record = state.fetch('nodes').fetch(@name)
        record['helpers'] ||= {}
        record['helpers'][identity.key] = { 'id' => id }
        @store.write(state)
      end

      def forget_helper(identity)
        node_phase do
          state = @store.load
          state.fetch('nodes').fetch(@name).fetch('helpers', {}).delete(identity.key)
          @store.write(state)
        end
      rescue Cancelled
        nil
      end

      def observe(state)
        check!(state, allow_cancelled: @phase_depth.positive?) if state || @generation
        @snapshots[state] = copy(state) if state
        state
      end

      def attach(record, lifecycle: false)
        @name = record.fetch('hostname')
        @instance = Node::Inventory.instance(record)
        @revision = lifecycle ? record['lifecycle_revision'] : nil
        check!
      end

      def check!(state = @store.read_state, allow_cancelled: false)
        return state if workspace_valid?(state, allow_cancelled) && node_valid?(state, allow_cancelled)

        raise Cancelled, 'Operation cancelled: its workspace or node instance was stopped or destroyed'
      end

      def resource(name)
        @store.resource_lock(name).synchronize do
          check!
          @phase_depth += 1
          begin
            result = yield
          ensure
            @phase_depth -= 1
          end
          check!
          result
        end
      end

      def force(*path)
        @forced << path
      end

      def refresh(state)
        @snapshots.fetch(state) { raise StateError, 'Unobserved inventory snapshot' }
        replace(state, check!)
        @snapshots[state] = copy(state)
      end

      # rubocop:disable-next Metrics/AbcSize -- Validate identity and atomically merge snapshot changes while retaining provider record references.
      def persist(state)
        baseline = @snapshots.fetch(state) { raise StateError, 'Unobserved inventory snapshot' }
        @store.with_lock do
          current = check!(@store.read_state, allow_cancelled: @phase_depth.positive?)
          merged = apply(copy(current), difference(baseline, state))
          @forced.each { |path| merged.dig(*path[0...-1])[path.last] = state.dig(*path) }
          @store.write_state(merged)
          replace(state, merged)
          @snapshots[state] = copy(state)
          @forced.clear
        end
      end

      private

      def workspace_valid?(state, allow_cancelled)
        return false unless state && state['generation'] == @generation

        @destructive || allow_cancelled || !(state['destroying'] || state['stopping'])
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Check immutable identity, deletion and optional lifecycle revision together.
      def node_valid?(state, allow_cancelled)
        return true unless @name

        record = state.fetch('nodes', {})[@name]
        return false unless record && Node::Inventory.instance(record) == @instance
        return true if @destructive || allow_cancelled

        !record['deleting'] && (!@revision || record['lifecycle_revision'] == @revision)
      end

      def copy(value)
        Marshal.load(Marshal.dump(value))
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity -- Distinguish absent keys from explicit nil while computing only changed inventory paths.
      def difference(before, after)
        return copy(after) unless before.is_a?(Hash) && after.is_a?(Hash)

        (before.keys | after.keys).each_with_object({}) do |key, patch|
          next if before.key?(key) && after.key?(key) && before[key] == after[key]

          patch[key] = after.key?(key) ? difference(before[key], after[key]) : REMOVED
        end
      end

      def apply(current, patch)
        return copy(patch) unless patch.is_a?(Hash)

        current = {} unless current.is_a?(Hash)

        patch.each do |key, value|
          if value.equal?(REMOVED)
            current.delete(key)
          else
            current[key] = apply(current[key], value)
          end
        end
        current
      end

      # Keep the record references held by providers and native adapters valid.
      # rubocop:disable-next Metrics/AbcSize -- Preserve mutable provider record references while replacing frozen definition metadata.
      def replace(target, source)
        (target.keys - source.keys).each { |key| target.delete(key) }
        source.each do |key, value|
          if target[key].is_a?(Hash) && !target[key].frozen? && value.is_a?(Hash)
            replace(target[key], value)
          else
            target[key] = copy(value)
          end
        end
      end
    end
  end
end
