# frozen_string_literal: true

module Empeira
  module Infrastructure
    # Coordinate shared control-plane resources without locking running node workloads.
    # rubocop:disable-next Metrics/ClassLength
    class Service
      def initialize(context:, runner:, runtimes:, build_info:, store: Store.new(context: context),
                     progress: Progress.new)
        @progress = progress
        @context = context
        @runner = runner
        @runtimes = runtimes
        @build_info = build_info
        @store = store
      end

      # rubocop:disable-next Metrics/AbcSize -- Read-only artifact validation precedes runtime mutation.
      def up
        require_compatible!
        initial = @store.operation_state
        runtime = mutation_runtime(initial)
        plane = control_plane(runtime)
        plane.validate
        allocate_network(runtime, initial)
        intent = initialize_intent(expected: initial)
        @store.with_operation(generation: intent.fetch('generation')) do |operation|
          @progress.stage(5, 'Checking runtime and workspace ownership...')
          result, changed = reconcile_control_plane(runtime, plane, operation)
          operation.check!
          changed = reconcile_nodes || changed
          operation.check!

          Providers::Result.new(resource: result.resource, changed: result.changed || changed)
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Validate shared service ownership before the serialized browser resource reconciliation.
      def browser
        require_compatible!
        state = @store.load
        raise Error, browser_workspace_error unless state

        @store.with_operation do |operation|
          @store.resource_lock("control-plane/#{operation.generation}").synchronize do
            operation.check!
            state = @store.load
            raise Error, browser_workspace_error unless state

            @progress.stage(5, 'Checking runtime and workspace ownership...')
            runtime = mutation_runtime(state)
            resource = observe(runtime, state)
            raise Error, browser_network_error unless resource

            verify_current!(state, resource)
            control_plane(runtime).browser
          end
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Quiesce creation before removing the dependent control-plane resources and retained state.
      def down
        require_compatible!
        return Providers::Result.new(resource: nil, changed: false) unless @store.load

        @store.with_operation(destructive: true) do |operation|
          @store.resource_lock("control-plane/#{operation.generation}").synchronize do
            @progress.stage(5, 'Checking runtime and workspace ownership...')
            state = @store.load
            runtime = mutation_runtime(state)
            resource = observe(runtime, state)
            @store.resource_lock('bridge-policy').synchronize do
              @store.with_lock do
                state = @store.load
                require_no_nodes!(state)
                state['stopping'] = true
                @store.write(state)
              end
            end

            changed = control_plane(runtime).down
            result = operation.resource('infrastructure-phase') do
              value = runtime.remove_network(definition: definition.network, expected_id: resource&.id)
              value
            end
            retain_storage
            Providers::Result.new(resource: result.resource, changed: result.changed || changed)
          end
        end
      end

      def destroy
        Cleanup.new(context: @context, runner: @runner, runtimes: @runtimes, progress: @progress).destroy
      end

      def status(verify: false)
        status = Status.new(context: @context, build_info: @build_info, definition: definition)
        state = @store.load
        status.record(state)
        runtime = runtime_for(state&.fetch('runtime') || @context.container_engine)
        runtime.check_available!
        status.observe(observe(runtime, state))
        health_report(status, runtime, state, verify: verify)
      rescue Error => e
        status.report.merge('Infrastructure' => 'unknown', 'Diagnostic' => e.message)
      end

      private

      def reconcile_control_plane(runtime, plane, operation)
        @store.resource_lock("control-plane/#{operation.generation}").synchronize do
          operation.check!
          plane.preflight
          result = operation.resource('infrastructure-phase') do
            state = @store.load
            resource = observe(runtime, state)
            verify_current!(state, resource)
            @progress.stage(15, 'Preparing isolated network...')
            ensure_network(runtime, state, resource)
          end
          [result, plane.up]
        end
      end

      def definition
        @definition ||= Definition.new(context: @context)
      end

      def browser_workspace_error
        "Workspace is not initialized. Start it with 'empeira up' first."
      end

      def browser_network_error
        "Required workspace network is not running. Start the workspace with 'empeira up' first."
      end

      def reconcile_nodes
        Node::Service.new(context: @context, runner: @runner, runtimes: @runtimes,
                          build_info: @build_info, progress: @progress).reconcile(state: @store.load)
      end

      def require_no_nodes!(state)
        return unless state&.fetch('nodes', {})&.any?

        raise Error, 'Nodes exist; destroy them before empeira down, or use empeira destroy for complete removal'
      end

      def health_report(status, runtime, state, verify:)
        policy_check = verify && status.report['Network'] == 'isolated'
        report = status.report.merge(control_plane(runtime).status(state: state, verify: policy_check))
        report['Network policy'] = 'unverified; workspace network isolation not verified' if verify && !policy_check
        if report['Infrastructure'] == 'up' &&
           (report['Control plane'] == 'degraded' || /\Aunverified/.match?(report['Network policy']))
          report['Infrastructure'] = 'degraded'
        end
        report
      end

      def allocate_network(runtime, state)
        @peer_network = state&.fetch('peer_network', nil) || {
          'subnet' => Network::Peer::Allocation.new(context: @context, runtime: runtime, runner: @runner).choose
        }
        definition.network.allocation = @peer_network.fetch('subnet')
        definition.plan.validate_network_redirects!(subnet: @peer_network.fetch('subnet'))
      end

      def ensure_network(runtime, state, resource)
        allocate_network(runtime, state)
        definition.network.policy.require_support!(**runtime.capabilities)
        persist(state, resource)
        result = if resource
                   Providers::Result.new(resource: resource, changed: false)
                 else
                   runtime.create_network(definition: definition.network)
                 end
        persist(state, result.resource) unless resource
        result
      end

      def retain_storage
        retained = @store.load
        if retained&.dig('control_plane', 'volumes')&.any?
          retained['resources']['network']['id'] = nil
          retained.delete('stopping')
          @store.write(retained)
        else
          @store.with_lock { @store.clear }
        end
      end

      def control_plane(runtime)
        ControlPlane::Controller.new(context: @context, runtime: runtime, store: @store, runner: @runner,
                                     plan: definition.plan, progress: @progress)
      end

      def requirement
        @context.configuration.fetch('requirements').fetch('empeira')
      end

      def require_compatible!
        @build_info.require_compatible!(requirement)
      end

      def runtime_for(name)
        @runtimes.build(name, context: @context, runner: @runner)
      end

      def runtime_mismatch?(state)
        state && state.fetch('runtime') != @context.container_engine
      end

      def mutation_runtime(state)
        if runtime_mismatch?(state)
          raise Error, "Existing infrastructure belongs to #{state.fetch('runtime')}, configured runtime is " \
                       "#{@context.container_engine}. Restore the owning runtime and remove retained infrastructure " \
                       'before switching. ' \
                       'Runtime migration is not implemented.'
        end
        runtime = runtime_for(@context.container_engine)
        runtime.check_available!
        runtime
      end

      def observe(runtime, state)
        network = definition.network
        expected_id = state&.dig('resources', 'network', 'id')
        resource = runtime.inspect_network(identifier: network.backend_name)
        network.verify_ownership!(resource, expected_id: expected_id)
        if resource.nil? && expected_id && runtime.inspect_network(identifier: expected_id)
          raise Providers::OwnershipError,
                'Recorded network ID exists under a different name; automatic removal refused'
        end

        resource
      end

      def verify_current!(state, resource)
        if state && (state.dig('definition', 'revision') != definition.metadata['revision'] ||
                     state.dig('component_fingerprints', 'network') != definition.component_fingerprints['network'])
          raise Error,
                'Infrastructure definition is stale. Inspect status, then explicitly run ' \
                'empeira destroy and empeira up.'
        end
        return unless resource

        definition.network.verify_definition!(resource)
        definition.network.verify_isolation!(resource)
      end

      # The inventory envelope is deliberately written atomically in one operation.
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity -- Validate identity and atomically merge snapshot changes while retaining provider record references.
      def persist(previous, resource)
        now = Time.now.utc.iso8601
        state = previous || @store.load || {}
        state.merge!(
          'schema_version' => Store::SCHEMA_VERSION, 'workspace' => @context.workspace.id,
          'runtime' => @context.container_engine,
          'resources' => { 'network' => { 'logical_identity' => definition.network.identity,
                                          'name' => definition.network.backend_name, 'id' => resource&.id } },
          'fingerprint' => definition.fingerprint, 'definition' => definition.metadata,
          'component_fingerprints' => definition.component_fingerprints,
          'created_at' => previous&.fetch('created_at') || now, 'reconciled_at' => now,
          'generation' => state['generation'] || SecureRandom.hex(16)
        )
        state['peer_network'] = @peer_network if @peer_network
        @store.write(state)
      end

      def initialize_intent(expected:)
        @store.with_lock do
          current = @store.load
          if expected && (!current || current['generation'] != expected['generation'])
            raise Cancelled, 'Operation cancelled: its workspace was destroyed or recreated during validation'
          end
          next current if current

          persist(nil, nil)
          @store.load
        end
      end
    end
  end
end
