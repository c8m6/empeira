# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require 'time'

module Empeira
  module Infrastructure
    class StateError < Error; end
    class Locked < Error; end

    # Keep atomic persistence and the complete inventory envelope validator together.
    # rubocop:disable-next Metrics/ClassLength
    class Store
      SCHEMA_VERSION = 2
      attr_reader :directory

      def initialize(context:)
        @workspace_id = context.workspace.id
        @network = Network::Definition.new(workspace: context.workspace, policy: Network::Policy.new)
        @directory = context.locations.workspace(context.workspace)
      end

      def with_lock
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.open(directory.join('mutation.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Locked, "Another Empeira mutation owns workspace #{@workspace_id}. Wait and retry."
          end

          begin
            yield
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      rescue SystemCallError
        raise StateError, 'Cannot access workspace mutation lock', cause: nil
      end

      def load
        data = JSON.parse(File.read(path))
        validate!(data)
        data
      rescue Errno::ENOENT
        raise StateError, 'Infrastructure state is an unreadable symlink' if path.symlink?

        nil
      rescue JSON::ParserError, SystemCallError
        raise StateError, 'Cannot read infrastructure state. Preserve it and investigate before retrying.', cause: nil
      end

      def write(data)
        validate!(data)
        Tempfile.create(['state-', '.json'], directory) do |file|
          file.chmod(0o600)
          file.write(JSON.pretty_generate(data))
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
      rescue SystemCallError, IOError
        raise StateError, 'Cannot persist infrastructure state. Run status before retrying.', cause: nil
      end

      def clear
        File.unlink(path) if path.exist?
      rescue SystemCallError
        raise StateError, 'Cannot clear infrastructure state. Run status before retrying.', cause: nil
      end

      private

      def path
        directory.join('infrastructure.json')
      end

      def validate!(data)
        unless data.is_a?(Hash) && data['schema_version'] == SCHEMA_VERSION && data['workspace'] == @workspace_id
          raise StateError,
                'Invalid infrastructure state schema or workspace. Preserve the state and inspect its ownership.'
        end
        if legacy_vm_network?(data)
          raise StateError,
                'Legacy VM gateway state: use the previous Empeira version to destroy this workspace, then recreate it'
        end
        validate_vm_layouts!(data)
        return if valid_inventory?(data)

        raise StateError, 'Invalid infrastructure inventory. Preserve it for recovery.'
      end

      def validate_vm_layouts!(data)
        nodes = data['nodes']
        return unless nodes.is_a?(Hash)

        nodes.each_value do |record|
          VM::Management.validate!(record) if record.is_a?(Hash) && record['provider'] == 'vm'
        end
      end

      def legacy_vm_network?(data)
        return true if data.key?('vm_gateway')
        return false if data.key?('peer_network') || !data['nodes'].is_a?(Hash)

        data['nodes'].values.any? { |record| record.is_a?(Hash) && record['provider'] == 'vm' }
      end

      def valid_inventory?(data)
        Runtime.registry.names.include?(data['runtime']) &&
          data['resources'].is_a?(Hash) && data['resources'].keys == ['network'] &&
          valid_network?(data['resources']['network']) &&
          valid_definition?(data) && valid_extensions?(data)
      end

      def valid_extensions?(data)
        valid_timestamps?(data) && valid_control_plane?(data) &&
          (!data.key?('nodes') || Node::Inventory.valid?(data['nodes'])) && valid_peer_network?(data) &&
          valid_bootstrap_proxy?(data['bootstrap_proxy'])
      end

      def valid_peer_network?(data)
        return true unless data.key?('peer_network')

        entry = data['peer_network']
        return false unless entry.is_a?(Hash) && entry.keys == ['subnet']

        layout = Network::Peer::Layout.new(entry['subnet'])
        valid_peer_leases?(data, layout) && valid_container_leases?(data, layout)
      rescue Infrastructure::StateError
        false
      end

      def valid_peer_leases?(data, layout)
        leases = data.fetch('nodes', {}).values.select { |record| record['provider'] == 'vm' }
                     .map { |record| record['peer'] }
        leases.all? { |lease| layout.valid_lease?(lease) && valid_transport?(lease) } &&
          leases.map { |lease| lease['ip'] }.uniq.size == leases.size
      end

      def valid_transport?(lease)
        %w[LinuxPodman DockerAdapter PodmanMachine].include?(lease['backend']) &&
          lease['dns'].is_a?(String) && IPAddr.new(lease['dns']).ipv4? &&
          Node::Inventory.valid_id?(lease['machine']) &&
          Node::Inventory.valid_certificate?(lease['helper_sha256'])
      rescue IPAddr::InvalidAddressError
        false
      end

      def valid_container_leases?(data, layout)
        records = data.fetch('nodes', {}).values.select { |record| record['provider'] == 'container' }
        addresses = records.map { |record| record.dig('definition', 'ip') }
        addresses.uniq.size == addresses.size && addresses.all? do |ip|
          (96..127).any? { |offset| layout.address(offset) == ip }
        end
      end

      def valid_bootstrap_proxy?(entry)
        entry.nil? || (entry.is_a?(Hash) && entry.keys == ['id'] && valid_resource_id?(entry['id']))
      end

      def valid_control_plane?(data)
        plane = data['control_plane']
        return true if plane.nil?
        return false unless plane.is_a?(Hash)

        !plane.key?('provider') &&
          valid_records?(plane['services'], /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/) &&
          valid_records?(plane['volumes'],
                         /\Aopenvox-(?:ca|ssl|server-data|postgres-data|puppetdb-data)\z/) &&
          valid_resource_id?(plane['egress']) &&
          valid_plane_metadata?(plane)
      end

      def valid_plane_metadata?(plane)
        flags = [plane['stopped'], plane['bridge_prepared']]
        flags.all? { |flag| [nil, true, false].include?(flag) } &&
          (plane['bridge_image'].nil? || plane['bridge_image'].is_a?(String)) &&
          (plane['gateway_policy'].nil? || valid_code_digest?(plane['gateway_policy'])) &&
          valid_proxy_reload?(plane['proxy_reload'])
      end

      def valid_proxy_reload?(checkpoint)
        return true if checkpoint.nil?

        checkpoint.is_a?(Hash) && checkpoint.keys.sort == %w[fingerprint id] &&
          checkpoint['id'].is_a?(String) && valid_resource_id?(checkpoint['id']) &&
          valid_code_digest?(checkpoint['fingerprint'])
      end

      def valid_code_digest?(value)
        value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
      end

      def valid_records?(records, pattern)
        records.is_a?(Hash) && records.all? do |key, value|
          key.is_a?(String) && key.match?(pattern) && value.is_a?(Hash) &&
            value.keys == ['id'] && valid_resource_id?(value['id'])
        end
      end

      def valid_definition?(data)
        data['definition'].is_a?(Hash) && data['definition']['revision'].is_a?(Integer) &&
          data['definition']['runtime'] == data['runtime'] &&
          data['fingerprint'] == Definition.fingerprint(data['definition'])
      end

      def valid_timestamps?(data)
        %w[created_at reconciled_at].all? { |key| data[key].is_a?(String) }
      end

      def valid_resource_id?(id)
        id.nil? || (id.is_a?(String) && id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/))
      end

      def valid_network?(network)
        network.is_a?(Hash) && network['logical_identity'] == @network.identity &&
          network['name'] == @network.backend_name &&
          valid_resource_id?(network['id'])
      end
    end
  end
end
