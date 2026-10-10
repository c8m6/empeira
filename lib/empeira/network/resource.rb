# frozen_string_literal: true

module Empeira
  module Network
    module ResourceIdentity
      private

      def valid_identity?(value)
        value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
      end

      def valid_labels?(labels)
        labels.is_a?(Hash) && labels.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
      end
    end

    # Identity and isolation only; this cannot stand in for a deletion membership observation.
    Binding = Data.define(:id, :name, :labels, :isolated) do
      include ResourceIdentity

      def initialize(id:, name:, labels:, isolated:)
        unless valid_identity?(id) && valid_identity?(name) && valid_labels?(labels) && [true, false].include?(isolated)
          raise Providers::ExecutionError, 'Runtime returned malformed network binding'
        end

        super(id: id.dup.freeze, name: name.dup.freeze, labels: Immutable.deep_freeze(labels.dup), isolated: isolated)
      end
    end

    Resource = Data.define(:id, :name, :labels, :isolated, :attachment_count) do
      include ResourceIdentity

      def initialize(id:, name:, labels:, isolated:, attachment_count:)
        unless valid_identity?(id) && valid_identity?(name) && valid_labels?(labels) &&
               valid_policy?(isolated, attachment_count)
          raise Providers::ExecutionError, 'Runtime returned malformed network data'
        end

        super(id: id.dup.freeze, name: name.dup.freeze, labels: Immutable.deep_freeze(labels.dup),
              isolated: isolated, attachment_count: attachment_count)
      end

      private

      def valid_policy?(isolated, count)
        [true, false].include?(isolated) && count.is_a?(Integer) && count >= 0
      end
    end
  end
end
