# frozen_string_literal: true

module Empeira
  module Network
    Resource = Data.define(:id, :name, :labels, :isolated, :attachment_count) do
      def initialize(id:, name:, labels:, isolated:, attachment_count:)
        unless valid_identity?(id) && valid_identity?(name) && valid_labels?(labels) &&
               valid_policy?(isolated, attachment_count)
          raise Providers::ExecutionError, 'Runtime returned malformed network data'
        end

        super(id: id.dup.freeze, name: name.dup.freeze, labels: Immutable.deep_freeze(labels.dup),
              isolated: isolated, attachment_count: attachment_count)
      end

      private

      def valid_identity?(value)
        value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
      end

      def valid_labels?(labels)
        labels.is_a?(Hash) && labels.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
      end

      def valid_policy?(isolated, count)
        [true, false].include?(isolated) && count.is_a?(Integer) && count >= 0
      end
    end
  end
end
