# frozen_string_literal: true

module Empeira
  module Infrastructure
    # Keep version gating and the single workspace mutation boundary together.
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
        @definition = Definition.new(context: context)
      end

      # rubocop:disable-next Metrics/AbcSize -- Read-only artifact validation precedes runtime mutation.
      def up
        require_compatible!
        @store.with_lock do
          @progress.stage(5, 'Checking runtime and workspace ownership...')
          state = @store.load
          runtime = mutation_runtime(state)
          resource = observe(runtime, state)
          verify_current!(state, resource)
          plane = control_plane(runtime)
          plane.preflight
          @progress.stage(15, 'Preparing isolated network...')
          result = ensure_network(runtime, state, resource)
          changed = plane.up
          changed = reconcile_nodes || changed

          Providers::Result.new(resource: result.resource, changed: result.changed || changed)
        end
      end

      def browser
        require_compatible!
        state = @store.load
        raise Error, browser_workspace_error unless state

        @store.with_lock do
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

      def down
        require_compatible!
        @store.with_lock do
          @progress.stage(5, 'Checking runtime and workspace ownership...')
          state = @store.load
          runtime = mutation_runtime(state)
          resource = observe(runtime, state)
          require_no_nodes!(state)

          changed = control_plane(runtime).down
          result = runtime.remove_network(definition: @definition.network, expected_id: resource&.id)
          retain_storage
          Providers::Result.new(resource: result.resource, changed: result.changed || changed)
        end
      end

      def destroy
        require_compatible!
        @store.with_lock do
          @progress.stage(5, 'Checking runtime and workspace ownership...')
          state = @store.load
          runtime = mutation_runtime(state)
          resource = observe(runtime, state)
          destroy_nodes(runtime, state) if state
          control_plane(runtime).destroy
          runtime.remove_network(definition: @definition.network, expected_id: resource&.id)
          @store.clear
        end
      end

      def status
        status = Status.new(context: @context, build_info: @build_info, definition: @definition)
        state = @store.load
        status.record(state)
        runtime = runtime_for(state&.fetch('runtime') || @context.container_engine)
        runtime.check_available!
        status.observe(observe(runtime, state))
        health_report(status, runtime, state)
      rescue Error => e
        status.report.merge('Infrastructure' => 'unknown', 'Diagnostic' => e.message)
      end

      private

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

      def destroy_nodes(runtime, state)
        Node::Container.new(context: @context, runner: @runner, backend: runtime).destroy_all(state: state)
        engine = VM.registry.build('qemu', context: @context, runner: @runner)
        Node::VM.new(context: @context, runner: @runner, backend: engine, runtime: runtime)
                .destroy_all(state: state)
      end

      def require_no_nodes!(state)
        return unless state&.fetch('nodes', {})&.any?

        raise Error, 'Nodes exist; destroy them before empeira down, or use empeira destroy for complete removal'
      end

      def health_report(status, runtime, state)
        report = status.report.merge(control_plane(runtime).status(state: state))
        if report['Infrastructure'] == 'up' && report['Control plane'] == 'degraded'
          report['Infrastructure'] = 'degraded'
        end
        report
      end

      def allocate_network(runtime, state)
        @peer_network = state&.fetch('peer_network', nil) || {
          'subnet' => Network::Peer::Allocation.new(context: @context, runtime: runtime, runner: @runner).choose
        }
        @definition.network.allocation = @peer_network.fetch('subnet')
        @definition.plan.validate_network_redirects!(subnet: @peer_network.fetch('subnet'))
      end

      def ensure_network(runtime, state, resource)
        allocate_network(runtime, state)
        @definition.network.policy.require_support!(**runtime.capabilities)
        persist(state, resource)
        result = if resource
                   Providers::Result.new(resource: resource, changed: false)
                 else
                   runtime.create_network(definition: @definition.network)
                 end
        persist(state, result.resource)
        result
      end

      def retain_storage
        retained = @store.load
        if retained&.dig('control_plane', 'volumes')&.any?
          retained['resources']['network']['id'] = nil
          @store.write(retained)
        else
          @store.clear
        end
      end

      def control_plane(runtime)
        ControlPlane::Controller.new(context: @context, runtime: runtime, store: @store, runner: @runner,
                                     plan: @definition.plan, progress: @progress)
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
        network = @definition.network
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
        if state && (state.dig('definition', 'revision') != @definition.metadata['revision'] ||
                     state.dig('component_fingerprints', 'network') != @definition.component_fingerprints['network'])
          raise Error,
                'Infrastructure definition is stale. Inspect status, then explicitly run ' \
                'empeira destroy and empeira up.'
        end
        return unless resource

        @definition.network.verify_definition!(resource)
        @definition.network.verify_isolation!(resource)
      end

      # The inventory envelope is deliberately written atomically in one operation.
      # rubocop:disable-next Metrics/AbcSize
      def persist(previous, resource)
        now = Time.now.utc.iso8601
        @store.write(
          'schema_version' => Store::SCHEMA_VERSION, 'workspace' => @context.workspace.id,
          'runtime' => @context.container_engine,
          'resources' => { 'network' => { 'logical_identity' => @definition.network.identity,
                                          'name' => @definition.network.backend_name, 'id' => resource&.id } },
          'fingerprint' => @definition.fingerprint, 'definition' => @definition.metadata,
          'component_fingerprints' => @definition.component_fingerprints, 'peer_network' => @peer_network,
          'created_at' => previous&.fetch('created_at') || now, 'reconciled_at' => now,
          **(previous&.key?('nodes') ? { 'nodes' => previous['nodes'] } : {}),
          **(previous&.key?('control_plane') ? { 'control_plane' => previous['control_plane'] } : {})
        )
      end
    end
  end
end
