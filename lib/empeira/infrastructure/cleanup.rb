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
          mark_workspace
          @store.resource_lock('teardown').synchronize do
            next unless @store.read_state

            @state = @store.load
            preempt_nodes
            @state.fetch('nodes', {}).dup.each_key { |name| attempt("node #{name}") { remove_node(name) } }
            remove_workspace
            @store.with_lock { @store.clear }
          end
        end
      end

      def node(name)
        hostname = name.downcase
        raise ConfigurationError, 'Invalid node hostname' unless Node::Inventory.valid_name?(hostname)

        transaction do
          attempt("node #{hostname}") { remove_node(hostname) }
          report_errors!
        end
      end

      private

      def preempt_nodes
        @state.fetch('nodes', {}).each do |name, record|
          attempt("interrupt node #{name}") do
            RecoveryInventory.node!(name, record)
            preempt(record)
          end
        end
      end

      def mark_workspace
        @store.resource_lock('bridge-policy').synchronize do
          @store.with_lock do
            @state = @store.load
            @state['destroying'] = true
            save
          end
        end
      end

      def remove_workspace
        @store.operation.resource('infrastructure-phase') do
          @state = @store.load
          @store.resource_lock('bootstrap-proxy').synchronize { remove_bootstrap }
          remove_services
          remove_volumes
          remove_networks
          reject_unknown_resources
          cleanup_files if @errors.empty?
          report_errors!
        end
      end

      def transaction
        @errors.clear
        @failures.clear
        @changed = false
        @store.with_operation(destructive: true) do
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
        record = mark_node(name)
        return unless record

        instance = Node::Inventory.instance(record)
        preempt(record)
        @store.operation.resource("node/#{name}") do
          @state = @store.load
          current = @state.fetch('nodes', {})[name]
          next unless current && Node::Inventory.instance(current) == instance

          finish_node(name, current)
        end
      end

      def finish_node(name, current)
        remove_helpers(current)
        Network::BootstrapProxy.new(context: @context, runtime: @runtime, store: @store).cleanup(@state,
                                                                                                 record: current)
        remove_native_node(current)
        retire_certificate(current)
        remove_discovery(current)
        save
        release_reservation(name, current)
        @changed = true
      end

      def release_reservation(name, record)
        @store.resource_lock('gateway-policy').synchronize do
          @state = @store.load
          release_gateway(record)
          @state.fetch('nodes').delete(name)
          save
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Revoke native and generated bootstrap exclusions before releasing the IP lease.
      def release_gateway(record)
        ip = record.dig('peer', 'ip') || record.dig('definition', 'ip')
        return unless ip

        IPAddr.new(ip)
        files = ControlPlane::Files.new(context: @context)
        path = Pathname(files.path('gateway.json'))
        return unless OwnedFiles.verify_removable!(path, root: @store.directory)

        policy = JSON.parse(path.read)
        policy['blocked'] = policy.fetch('blocked') - [ip]
        unblock_gateway(ip)
        files.write('gateway.json', JSON.generate(policy))
      rescue JSON::ParserError, IPAddr::InvalidAddressError
        raise StateError, 'Gateway policy or node address is invalid; ownership retained for recovery', cause: nil
      end

      def unblock_gateway(ip)
        id = @state.dig('control_plane', 'services', 'gateway', 'id')
        return unless id

        resource = @runtime.inspect_service(identity('gateway'), expected_id: id)
        return unless resource && resource['state'] == 'running'

        result = @runtime.service_exec(resource, [Network::Gateway::EXECUTABLE, 'unblock', ip])
        return if result.success?

        detail = Execution::Diagnostics.native(result, operation: 'Node gateway cleanup', tool: 'gateway')
        raise Error, "Cannot revoke the removed node's gateway exclusion\n#{detail}"
      end

      def remove_native_node(record)
        if record['provider'] == 'vm'
          VM::Removal.new(context: @context, runner: @runner, runtime: @runtime, store: @store).remove(record, @state)
        else
          remove_container_instance(record)
        end
      end

      def mark_node(name)
        @store.with_lock do
          @state = @store.load
          entry = @state.fetch('nodes', {})[name]
          next unless entry

          RecoveryInventory.node!(name, entry)
          entry['deleting'] = true
          entry['lifecycle_revision'] = SecureRandom.hex(16)
          save
          entry
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Verify paths and native ownership before interrupting the recorded provider instance.
      def preempt(record)
        directory = record['provider'] == 'vm' ? 'vms' : 'containers'
        OwnedFiles.verify_removable!(@store.directory.join(directory, record.fetch('hostname')), root: @store.directory)
        if record['provider'] == 'vm'
          engine = VM.registry.build('qemu', context: @context, runner: @runner)
          qemu = VM::QemuRuntime.new(engine: engine, runner: @runner, context: @context)
          qemu.stop(record, immediate: true) if record['pid'] || qemu.running?(record)
        elsif record['id']
          definition = Node::Definition.new(hostname: record.fetch('hostname'), workspace: @context.workspace)
          resource = @runtime.inspect_service(definition, expected_id: record.fetch('id'))
          verify_container_network!(resource, record) if resource
          remove_service(definition, record.fetch('id'))
        end
      end

      def remove_helpers(record)
        record.fetch('helpers', {}).dup.each do |key, entry|
          unless key.match?(/\Aagent-[0-9a-f]{32}\z/)
            raise StateError, 'Invalid agent helper identity; resources retained'
          end

          definition = identity(key)
          resource = @runtime.inspect_service(definition, expected_id: entry.fetch('id'))
          remove_service(definition, resource.fetch('id')) if resource
          record.fetch('helpers').delete(key)
          save
        end
      end

      def remove_container_instance(record)
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

      # Remove this lease before releasing its hostname/IP, without reinterpreting recovery configuration.
      # rubocop:disable-next Metrics/AbcSize -- Revoke aliases and proxy grants before releasing this hostname and address.
      def remove_discovery(record)
        @store.resource_lock('discovery').synchronize do
          files = ControlPlane::Files.new(context: @context)
          name = record.fetch('hostname')
          address = record.dig('peer', 'ip') || record.dig('definition', 'ip')
          aliases = Network::Naming.new.aliases(name)
          prune_file(files, 'hosts') { |lines| lines.reject { |line| line.split.drop(1).intersect?(aliases) } }
          if address
            prune_file(files, 'proxy-clients') { |lines| lines.reject { |line| line.strip == address } }
            prune_proxy_rules(files, address)
            reload_proxy
          end
        end
      end

      def prune_proxy_rules(files, address)
        prune_file(files, 'proxy-rules.conf') do |lines|
          labels = lines.filter_map do |line|
            match = line.match(/\Aacl (node_\d+)_source src (\S+)\s*\z/)
            match[1] if match && match[2] == address
          end
          lines.reject { |line| labels.any? { |label| line.match?(/\b#{Regexp.escape(label)}_/) } }
        end
      end

      def prune_file(files, name)
        path = Pathname(files.path(name))
        return unless OwnedFiles.verify_removable!(path, root: @store.directory)

        files.write(name, yield(path.readlines).join)
      end

      def reload_proxy
        id = @state.dig('control_plane', 'services', 'proxy', 'id')
        return unless id

        resource = @runtime.inspect_service(identity('proxy'), expected_id: id)
        @runtime.reload_service(resource) if resource && resource['state'] == 'running'
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
                         gateway_policy proxy_reload dns_definition database_setup]
        unknown = plane.keys - known_plane
        @errors << "Unrecognized control-plane fields retained: #{unknown.join(', ')}" unless unknown.empty?
        return unless @state.key?('vm_gateway')

        @errors << 'Legacy VM gateway ownership is not safely interpretable; state retained'
      end

      def cleanup_files
        %w[containers vms services bootstrap-proxy environments additional-configurations puppetdb-relay
           database.env].each do |name|
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
