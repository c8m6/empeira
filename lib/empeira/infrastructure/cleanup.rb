# frozen_string_literal: true

module Empeira
  module Infrastructure
    # One recovery transaction over the existing inventory and native lifecycle adapters.
    # rubocop:disable-next Metrics/ClassLength -- One recovery transaction retains ownership until native removals are confirmed.
    class Cleanup
      def initialize(context:, runner:, runtimes: Runtime.registry, runtime: nil, progress: Progress.new)
        @context = context
        @runner = runner
        @runtimes = runtimes
        @runtime = runtime
        @progress = progress
        @store = Store.new(context: context, recovery: true)
        @errors = []
        @failures = []
        @changed = false
      end

      def destroy
        transaction do
          @state.fetch('nodes', {}).dup.each_key { |name| attempt("node #{name}") { remove_node(name) } }
          remove_bootstrap
          remove_services
          remove_volumes
          remove_networks
          reject_unknown_resources
          if @errors.empty?
            cleanup_files
            @store.clear
          end
          report_errors!
        end
      end

      def node(name)
        hostname = name.downcase
        raise ConfigurationError, 'Invalid node hostname' unless Node::Inventory.valid_name?(hostname)

        transaction do
          attempt("node #{hostname}") { remove_node(hostname) }
          attempt('node discovery records') { remove_dns(hostname) } unless @state.fetch('nodes', {}).key?(hostname)
          report_errors!
        end
      end

      private

      def transaction
        @errors.clear
        @failures.clear
        @changed = false
        @store.with_lock do
          @state = @store.load
          next Providers::Result.new(resource: nil, changed: false) unless @state

          @runtime ||= @runtimes.build(@state.fetch('runtime'), context: @context, runner: @runner)
          @runtime.check_available!
          yield
          Providers::Result.new(resource: nil, changed: @changed)
        end
      end

      def attempt(identity)
        yield
      rescue Error, SystemCallError, KeyError, ArgumentError => e
        @failures << e
        diagnostic = Execution::Diagnostics.safe_text(e.message)
        @errors << "#{identity}: #{diagnostic}"
      rescue TypeError, NoMethodError => e
        @failures << e
        @errors << "#{identity}: Resource fields cannot be safely interpreted (#{e.class.name}); retained"
      end

      def save
        @store.write(@state)
      end

      def report_errors!
        return if @errors.empty?

        failure = @failures.any? && @failures.all?(Locked) ? Locked : Error
        raise failure, "Cleanup is incomplete; inventory and remaining ownership data retained.\n#{@errors.join("\n")}",
              cause: nil
      end

      def remove_node(name)
        record = @state.fetch('nodes', {})[name]
        return unless record

        RecoveryInventory.node!(name, record)
        if record['provider'] == 'vm'
          VM::Removal.new(context: @context, runner: @runner, runtime: @runtime, store: @store).remove(record, @state)
        else
          remove_container(record)
        end
        retire_certificate(record)
        remove_session_lock(record) if record['provider'] == 'vm'
        @state.fetch('nodes').delete(name)
        save
        @changed = true
      end

      def remove_session_lock(record)
        path = @store.directory.join("vm-session-#{record.fetch('peer').fetch('token')}.lock")
        OwnedFiles.remove(path, root: @store.directory)
      end

      def remove_container(record)
        name = record.fetch('hostname')
        path = @store.directory.join('containers', name)
        OwnedFiles.verify_removable!(path, root: @store.directory)
        definition = Node::Definition.new(hostname: name, workspace: @context.workspace)
        resource = @runtime.inspect_service(definition, expected_id: record['id'])
        if resource
          verify_container_network!(resource, record)
          recover_container_id!(resource, record) unless record['id']
          remove_service(definition, record['id'])
        end
        OwnedFiles.remove(path, root: @store.directory)
      end

      def verify_container_network!(resource, record)
        network = Network::Definition.new(workspace: @context.workspace, policy: Network::Policy.new).backend_name
        return if resource.fetch('networks').keys == [network] && Node::SSHEndpoint.valid?(resource, record)

        raise Providers::OwnershipError, 'Node has unexpected network membership or published ports; retained'
      end

      # rubocop:disable-next Metrics/AbcSize -- Match persisted random instance intent before recording a recovered ID.
      def recover_container_id!(resource, record)
        options = record.fetch('definition')
        definition = Node::Definition.new(hostname: record.fetch('hostname'), workspace: @context.workspace,
                                          **options.except('hostname').transform_keys(&:to_sym))
        network = resource.fetch('networks').values.first
        mac = options['mac_address']
        unless mac.is_a?(String) && mac.match?(/\A02:(?:[0-9a-f]{2}:){4}[0-9a-f]{2}\z/) &&
               network['MacAddress'] == mac && resource.dig('labels', 'io.empeira.definition') == definition.fingerprint
          raise Providers::OwnershipError, 'Uncertain node creation has no matching instance intent; retained'
        end

        record['id'] = resource.fetch('id')
        save
      end

      def retire_certificate(record)
        key = record['certificate_key']
        return unless key
        unless Node::Inventory.valid_certificate?(key)
          raise StateError, 'Recorded certificate identity is invalid; ownership data retained'
        end

        @state['retired_certificates'] ||= {}
        @state.fetch('retired_certificates')[record.fetch('hostname')] = key
      end

      def remove_dns(name)
        files = ControlPlane::Files.new(context: @context)
        path = Pathname(files.path('hosts'))
        return unless OwnedFiles.verify_removable!(path, root: @store.directory)

        aliases = Network::Naming.new.aliases(name)
        content = path.readlines.reject { |line| line.split.drop(1).intersect?(aliases) }.join
        @changed = files.write('hosts', content) || @changed
      end

      def remove_service(definition, id)
        raise StateError, 'Invalid recorded service ID' unless Node::Inventory.valid_id?(id)

        resource = @runtime.inspect_service(definition, expected_id: id)
        return unless resource
        raise Providers::OwnershipError, 'Service has no recorded instance ID; resource retained' unless id

        @runtime.remove_service(definition, expected_id: id)
      end

      def identity(key)
        unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/)
          raise StateError, 'Invalid service identity; resource retained'
        end

        Services::Definition.new(key: key, workspace: @context.workspace)
      end

      def plane
        @state.fetch('control_plane', {})
      end

      def remove_bootstrap
        return unless @state.key?('bootstrap_proxy')

        attempt('bootstrap-proxy') do
          remove_service(identity('bootstrap-proxy'), @state.fetch('bootstrap_proxy').fetch('id'))
          @state.delete('bootstrap_proxy')
          save
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Preserve gateway dependencies while continuing independent service cleanup.
      def remove_services
        records = plane.fetch('services', {})
        keys = (records.keys - %w[proxy dns gateway]).reverse + %w[proxy dns gateway]
        keys.each do |key|
          next unless records.key?(key)
          next if key == 'gateway' && @state.fetch('nodes', {}).any?

          attempt("service #{key}") do
            remove_service(identity(key), records.fetch(key).fetch('id'))
            records.delete(key)
            save
          end
        end
      end

      def remove_volumes
        records = plane.fetch('volumes', {})
        records.dup.each_key do |key|
          attempt("volume #{key}") do
            remove_volume(identity(key), records.fetch(key).fetch('id'))
            records.delete(key)
            save
          end
        end
      end

      def remove_volume(definition, id)
        raise StateError, 'Invalid recorded volume ID' unless Node::Inventory.valid_id?(id)

        resource = @runtime.inspect_volume(definition, expected_id: id)
        return unless resource

        raise Providers::OwnershipError, 'Volume has no recorded instance ID; resource retained' unless id

        @runtime.remove_volume(definition, expected_id: id)
      end

      # rubocop:disable-next Metrics/AbcSize -- Independent network teardown follows confirmed node and bridge removal.
      def remove_networks
        if @state.fetch('nodes', {}).any?
          @errors << 'Shared network and gateway retained while node cleanup is incomplete'
          return
        end
        remove_bridge
        attempt('egress network') do
          definition = Network::Egress.new(workspace: @context.workspace, policy: Network::Policy.new)
          remove_network(definition, plane['egress'])
          plane['egress'] = nil if @state.key?('control_plane')
          save
        end
        attempt('environment network') { remove_environment_network }
      end

      # rubocop:disable-next Metrics/AbcSize -- Check recorded logical identity before native network removal.
      def remove_environment_network
        raise StateError, 'Workspace bridge cleanup is incomplete; network retained' if plane['bridge_prepared']

        entry = @state.fetch('resources').fetch('network')
        definition = Network::Definition.new(workspace: @context.workspace, policy: Network::Policy.new)
        unless [nil, definition.identity].include?(entry['logical_identity']) &&
               [nil, definition.backend_name].include?(entry['name'])
          raise Providers::OwnershipError, 'Recorded network identity is inconsistent; network retained'
        end

        remove_network(definition, entry['id'])
        entry['id'] = nil
        save
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Native bridge teardown uses only recorded owner, ID and allocation.
      def remove_bridge
        return unless plane['bridge_prepared']

        attempt('workspace bridge') do
          definition = Network::Definition.new(workspace: @context.workspace, policy: Network::Policy.new)
          id = @state.dig('resources', 'network', 'id')
          resource = @runtime.inspect_network(identifier: definition.backend_name)
          if resource
            definition.verify_ownership!(resource, expected_id: id)
            raise Providers::OwnershipError, 'Bridge has no recorded network ID' unless id

            definition.allocation = @state.fetch('peer_network').fetch('subnet')
            @runtime.reconcile_workspace_bridge(definition: definition, expected_id: id,
                                                image: plane.fetch('bridge_image'), action: 'remove')
          end
          plane.delete('bridge_prepared')
          plane.delete('bridge_image')
          save
        end
      end

      def remove_network(definition, id)
        raise StateError, 'Invalid recorded network ID' unless Node::Inventory.valid_id?(id)

        resource = @runtime.inspect_network(identifier: definition.backend_name)
        definition.verify_ownership!(resource, expected_id: id)
        if resource
          raise Providers::OwnershipError, 'Network has no recorded instance ID; resource retained' unless id

          @runtime.remove_network(definition: definition, expected_id: id)
        elsif id && @runtime.inspect_network(identifier: id)
          raise Providers::OwnershipError, 'Recorded network ID exists with a different identity; resource retained'
        end
      end

      def reject_unknown_resources
        unknown = @state.fetch('resources').keys - ['network']
        @errors << "Unrecognized resource groups retained: #{unknown.join(', ')}" unless unknown.empty?
        known_plane = %w[services volumes egress bridge_prepared bridge_image stopped environment_cache
                         gateway_policy proxy_reload]
        unknown = plane.keys - known_plane
        @errors << "Unrecognized control-plane fields retained: #{unknown.join(', ')}" unless unknown.empty?
        return unless @state.key?('vm_gateway')

        @errors << 'Legacy VM gateway ownership is not safely interpretable; state retained'
      end

      def cleanup_files
        %w[containers vms services environments additional-configurations puppetdb-relay database.env].each do |name|
          OwnedFiles.remove(@store.directory.join(name), root: @store.directory, symlinks: name == 'environments')
        end
        locks = @store.directory.children.select do |path|
          path.basename.to_s.match?(/\Avm-session-[0-9a-f]{32}\.lock\z/)
        end
        locks.each { |path| OwnedFiles.remove(path, root: @store.directory) }
      end
    end
  end
end
