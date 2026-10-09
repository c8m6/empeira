# frozen_string_literal: true

module Empeira
  module Node
    # Public logical node provider; QEMU and container networking stay replaceable.
    class VM < Interface
      include VMState
      include VMPreflight
      include VMPreparation
      include VMLifecycle

      def initialize(context:, runner:, backend:, runtime:, build_info: BuildInfo.load, progress: Progress.new)
        super(name: 'vm', context: context, runner: runner, backend: backend)
        @engine = backend
        @runtime = runtime
        @build_info = build_info
        @progress = progress
        @store = Infrastructure::Store.new(context: context)
        prepare_components(context, runner, backend, runtime)
      end

      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates guest resources.
      def reconcile_all(state:)
        load_state(state)
        vm_records.values.map do |record|
          next false if context.configuration.dig('mocks', 'commands').empty? &&
                        record.fetch('command_mocks', {}).empty?

          record['provisioned'] && @qemu.running?(record) ? reconcile_command_mocks(record) : false
        end.any?
      end

      private

      def reconcile_command_mocks(record)
        CommandMocks.new(context: context, record: record, persist: method(:save),
                         execute: ->(arguments) { @ssh.run(record, arguments) }).reconcile
      end

      def prepare_components(context, runner, backend, runtime)
        @peer = Network::Peer::Backend.build(context: context, runtime: runtime, runner: runner, store: @store)
        @bootstrap_proxy = Network::BootstrapProxy.new(context: context, runtime: runtime, store: @store)
        @source = ::Empeira::VM::ImageSource.new
        @cache = ::Empeira::VM::ImageCache.new(locations: context.locations)
        @disk = ::Empeira::VM::Disk.new(engine: backend, runner: runner,
                                        workspace_directory: context.locations.workspace(context.workspace))
        @qemu = ::Empeira::VM::QemuRuntime.new(engine: backend, runner: runner, context: context)
        @cloud = ::Empeira::VM::CloudInit.new(context: context, runner: runner)
        @ssh = ::Empeira::VM::SSH.new(context: context, runner: runner, cloud_init: @cloud)
        @agent = ::Empeira::VM::Agent.new(context: context, ssh: @ssh, runtime: runtime, progress: @progress)
      end
    end
  end
end
