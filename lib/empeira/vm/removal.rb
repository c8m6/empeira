# frozen_string_literal: true

module Empeira
  module VM
    # Removal validates host ownership and never contacts the guest or verifies base-image contents.
    class Removal
      def initialize(context:, runner:, runtime:, store:)
        @context = context
        @runner = runner
        @runtime = runtime
        @store = store
      end

      def remove(record, state)
        root = @store.directory
        path = root.join('vms', record.fetch('hostname'))
        Infrastructure::OwnedFiles.verify_removable!(path, root: root)
        SessionLock.new(context: @context, record: record).exclusive do
          engine = VM.registry.build('qemu', context: @context, runner: @runner)
          qemu = QemuRuntime.new(engine: engine, runner: @runner, context: @context)
          peer = Network::Peer::Backend.build(context: @context, runtime: @runtime, runner: @runner, store: @store)
          qemu.stop(record)
          peer.destroy(record, state)
          qemu.cleanup(record)
          Infrastructure::OwnedFiles.remove(path, root: root)
        end
      end
    end
  end
end
