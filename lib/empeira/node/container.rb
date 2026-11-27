# frozen_string_literal: true

module Empeira
  module Node
    # Container provider owns its workflow; the public service only routes logical providers.
    # rubocop:disable-next Metrics/ClassLength -- Ordered provisioning and lifecycle share this provider boundary.
    class Container < Interface
      include ContainerLifecycle
      include ContainerPreparation
      include ContainerAgentBootstrap
      include ContainerState
      include ContainerGuest
      include Transaction

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

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Verify retired certificate ownership before the existing enrollment transaction.
      def run(request)
        mutate do
          @progress.stage(10, 'Checking control plane and reserving hostname...')
          server = ready_server
          record, definition, image = reserve_container(request)
          @store.operation.attach(record, lifecycle: true)
          prepare_image(image, record)
          resource = create_node(definition, record)
          @progress.stage(65, 'Preparing node certificate...')
          certificates = Certificates.new(runtime: @runtime, server: server, guard: @store.operation.method(:check!))
          instance_phase(record) do
            certificates.clean_retired(@state, record.fetch('hostname')) { save } if @state['retired_certificates']
            certificates.enroll(resource, record) { save }
          end
          reconcile_guest(resource, record)
          complete_provisioning(record)
          @store.operation.attach(record)
          @progress.stage(85, 'Running Puppet agent...')
          InitialPuppetRuns.new(count: context.configuration.dig('node_defaults', 'puppet_runs'), progress: @progress)
                           .run { agent_run(resource, record, initial: true) }
          lifecycle_result(record['hostname'], :running, changed: true)
        end
      end

      def reconcile_all(state:)
        reconcile_instances(state, 'container') do |record|
          resource = observed(record)
          instance_phase(record) { network_gateway.route(resource) } if resource && resource['state'] == 'running'
          next false unless record['provisioned'] && resource && resource['state'] == 'running'

          reconcile_guest(resource, record)
        end
      end

      private

      def complete_provisioning(record)
        instance_phase(record) do
          record['provisioned'] = true
          save
        end
      end

      def reconcile_command_mocks(resource, record)
        CommandMocks.new(context: context, record: record, persist: method(:save),
                         execute: ->(arguments) { @runtime.service_exec(resource, arguments) }).reconcile
      end

      def prepare_image(image, record)
        @progress.stage(25, 'Preparing node image...')
        @runtime.with_local_images do
          @runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
          return if @runtime.image_architecture(image.reference) == record['architecture']
        end

        raise Error, 'Node image architecture differs from the runtime; emulation is not enabled'
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Ordered bootstrap cleanup precedes normal guest policy.
      def create_node(definition, record)
        @progress.stage(45, 'Creating isolated container node...')
        resource = instance_phase(record) do
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
          resource
        end
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
