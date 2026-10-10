# frozen_string_literal: true

module Empeira
  module Node
    # Container provider owns its workflow; the public service only routes logical providers.
    class Container < Interface
      include ContainerLifecycle
      include ContainerPreparation
      include ContainerAgentBootstrap
      include ContainerState
      include ContainerGuest

      attr_reader :context

      def initialize(context:, runner:, backend:, build_info: BuildInfo.load, progress: Progress.new)
        super(name: 'container', context: context, runner: runner, backend: backend)
        @runtime = backend
        @build_info = build_info
        @progress = progress
        @store = Infrastructure::Store.new(context: context)
        @bootstrap_proxy = Network::BootstrapProxy.new(context: context, runtime: @runtime, store: @store)
      end

      def available?
        @runtime.available?
      end

      def run(request)
        mutate do
          @progress.stage(10, 'Checking control plane and reserving hostname...')
          server = ready_server
          record, definition, image = reserve(request)
          prepare_image(image, record)
          resource = create_node(definition, record)
          @progress.stage(65, 'Preparing node certificate...')
          Certificates.new(runtime: @runtime, server: server).enroll(resource, record) { save }
          complete_provisioning(record)
          @progress.stage(85, 'Running Puppet agent...')
          agent_run(resource, record)
          lifecycle_result(record['hostname'], :running, changed: true)
        end
      end

      def destroy_all(state:)
        @state = state
        @nodes = state.fetch('nodes', {})
        @nodes.each { |name, record| remove_node(name, certificates: false) if record['provider'] == 'container' }
      end

      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates guest resources.
      def reconcile_all(state:)
        @state = state
        @nodes = state.fetch('nodes', {})
        container_records.values.map do |record|
          resource = observed(record)
          network_gateway.route(resource) if resource && resource['state'] == 'running'
          next false unless record['provisioned'] && resource && resource['state'] == 'running'

          reconcile_guest(resource, record)
        end.any?
      end

      private

      def complete_provisioning(record)
        record['provisioned'] = true
        save
      end

      def reconcile_command_mocks(resource, record)
        CommandMocks.new(context: context, record: record, persist: method(:save),
                         execute: ->(arguments) { @runtime.service_exec(resource, arguments) }).reconcile
      end

      def prepare_image(image, record)
        @progress.stage(25, 'Preparing node image...')
        @runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
        return if @runtime.image_architecture(image.reference) == record['architecture']

        raise Error, 'Node image architecture differs from the runtime; emulation is not enabled'
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Ordered bootstrap cleanup precedes normal guest policy.
      def create_node(definition, record)
        @progress.stage(45, 'Creating isolated container node...')
        resource = @runtime.create_service(definition)
        record['id'] = resource.fetch('id')
        record['image_id'] = resource['image_id']
        save
        network_gateway.phase(record, bootstrap: true)
        @runtime.start_service(resource)
        resource = observed(record)
        network_gateway.route(resource)
        record['ssh_port'] = SSHEndpoint.port(resource) if record['ssh_transport'] == 'loopback'
        save
        apply_bootstrap(resource, record)
        finish_network_bootstrap(record)
        prepare_guest_environment(resource, record)
        configure(resource, record)
        resource
      end

      def apply_bootstrap(resource, record)
        apply_agent_bootstrap(resource, record)
      ensure
        @bootstrap_proxy.cleanup(@state) if @state
      end

      def package_bootstrap(resource, record)
        execute = ->(arguments) { @runtime.service_exec(resource, arguments, timeout: 300) }
        requirements = package_requirements(record)
        PackageBootstrap.new(config: context.configuration.dig('bootstrap', 'packages'),
                             os: record.fetch('os'), execute: execute,
                             copy: guest_copy(resource, execute),
                             rpm_options: requirements.rpm_options,
                             progress: @progress.method(:heartbeat))
      end

      def package_requirements(record, agent_required: false)
        ::Empeira::VM::BootstrapRequirements.new(context: context, os: record.fetch('os'),
                                                 version: record.fetch('version'), agent_required: agent_required,
                                                 distribution_required: true,
                                                 architecture: record.fetch('architecture'))
      end
    end
  end
end
