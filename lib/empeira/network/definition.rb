# frozen_string_literal: true

module Empeira
  module Network
    class Definition
      LABEL_PREFIX = 'io.empeira'
      attr_reader :workspace, :policy
      attr_accessor :allocation

      def initialize(workspace:, policy:, revision: 2)
        @workspace = workspace
        @policy = policy
        @revision = revision
      end

      def identity
        "#{workspace.id}:environment"
      end

      def backend_name
        "empeira-#{workspace.id}-network"
      end

      def labels
        ownership_labels.merge('io.empeira.definition' => Infrastructure::Definition.fingerprint(to_h))
      end

      def ownership_labels
        { "#{LABEL_PREFIX}.managed-by" => 'empeira', "#{LABEL_PREFIX}.workspace" => workspace.id,
          "#{LABEL_PREFIX}.purpose" => 'environment-network' }
      end

      def verify_ownership!(resource, expected_id: nil)
        return unless resource

        owned = resource.name == backend_name && ownership_labels.all? { |key, value| resource.labels[key] == value }
        return if owned && (expected_id.nil? || resource.id == expected_id)

        raise Providers::OwnershipError, "Network ownership or recorded ID conflicts for workspace #{workspace.id}"
      end

      def verify_definition!(resource)
        return if resource.labels['io.empeira.definition'] == labels.fetch('io.empeira.definition')

        raise Error, 'Network definition is stale or unknown. Run empeira down before recreating it.'
      end

      def verify_isolation!(resource)
        return if resource&.isolated == true

        raise UnsupportedPolicy, "Cannot verify isolated network for workspace #{workspace.id}"
      end

      def to_h
        { 'identity' => identity, 'backend_name' => backend_name,
          'policy' => { 'isolated' => true, 'controlled_egress' => false },
          'labels' => ownership_labels, 'revision' => @revision }
      end
    end
  end
end
