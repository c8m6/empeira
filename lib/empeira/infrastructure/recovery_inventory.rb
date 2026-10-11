# frozen_string_literal: true

module Empeira
  module Infrastructure
    # Recovery reads ownership, never migrates schemas or interprets guest configuration.
    module RecoveryInventory
      def self.validate!(data, workspace:)
        return if valid_envelope?(data, workspace) && valid_retired_certificates?(data)

        raise StateError, 'Recovery inventory ownership or resource envelope is invalid; preserve the state'
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity -- Validate the complete recoverable ownership envelope.
      def self.valid_envelope?(data, workspace)
        data.is_a?(Hash) && data['workspace'] == workspace &&
          data['schema_version'].is_a?(Integer) && data['schema_version'].positive? &&
          Runtime.registry.names.include?(data['runtime']) && data['resources'].is_a?(Hash) &&
          data.fetch('nodes', {}).is_a?(Hash) && valid_plane?(data.fetch('control_plane', {}))
      end

      def self.valid_plane?(plane)
        plane.is_a?(Hash) && %w[services volumes].all? { |key| plane.fetch(key, {}).is_a?(Hash) }
      end

      def self.valid_retired_certificates?(data)
        entries = data.fetch('retired_certificates', {})
        entries.is_a?(Hash) && entries.all? do |name, key|
          Node::Inventory.valid_name?(name) && key.is_a?(String) && key.match?(/\A[0-9a-f]{64}\z/)
        end
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Validate identity before dispatching numeric-root host cleanup.
      def self.node!(name, record)
        unless Node::Inventory.valid_name?(name) && record.is_a?(Hash) && record['hostname'] == name &&
               %w[container vm].include?(record['provider']) && Node::Inventory.valid_id?(record['id'])
          raise StateError, 'Node identity is not safely interpretable; resources retained'
        end
        return if record['provider'] == 'container'

        return if valid_vm_instance?(name, record)

        raise StateError, 'VM instance or disk identity is incomplete; resources retained'
      end

      def self.valid_vm_instance?(name, record)
        peer = record['peer']
        valid_token = peer.is_a?(Hash) && peer['token'].is_a?(String) && peer['token'].match?(/\A[0-9a-f]{32}\z/)
        valid_pid = record['pid'].nil? || (record['pid'].is_a?(Integer) && record['pid'].positive?)
        valid_token && valid_pid && record['overlay'] == "vms/#{name}/disk.qcow2"
      end
    end
  end
end
