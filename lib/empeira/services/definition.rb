# frozen_string_literal: true

module Empeira
  module Services
    # This domain describes containers without selecting a container engine.
    class Definition
      attr_reader :key, :options, :workspace

      def initialize(key:, workspace:, **options)
        @key = key
        @workspace = workspace
        @options = Immutable.deep_freeze(options.transform_keys(&:to_s))
      end

      def name
        "empeira-#{workspace.id}-#{key}"
      end

      def fingerprint
        Infrastructure::Definition.fingerprint(options.except('dns', 'runtime_environment', 'runtime_ip'))
      end

      def ownership_labels
        { 'io.empeira.managed-by' => 'empeira', 'io.empeira.workspace' => workspace.id,
          'io.empeira.purpose' => key }
      end

      def labels
        ownership_labels.merge('io.empeira.definition' => fingerprint)
      end

      def verify!(resource, expected_id: nil)
        return unless resource
        return if resource.fetch('name') == name &&
                  ownership_labels.all? { |key, value| resource.fetch('labels')[key] == value } &&
                  (expected_id.nil? || expected_id == resource.fetch('id'))

        raise Providers::OwnershipError, "Service resource ownership or recorded ID conflicts: #{key}"
      end
    end
  end
end
