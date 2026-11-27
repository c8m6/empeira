# frozen_string_literal: true

require 'fileutils'

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- Node lifecycle pins instance identity around native resource phases.
    module VMLifecycle
      # rubocop:disable-next Metrics/AbcSize -- Keep native resource creation and readiness separate from brief identity publication.
      def start(name:)
        mutate do
          record = fetch_vm(name)
          unless record['provisioned']
            raise Error, 'VM bootstrap is incomplete; inspect logs, then destroy and recreate the node'
          end

          record = claim_lifecycle(name)

          validate_interfaces(record)
          ready_server
          return lifecycle_result(name.downcase, :running, changed: reconcile_guest(record)) if @qemu.running?(record)

          @progress.stage(1, 'Checking VM control-plane readiness...')
          @engine.preflight!(progress: @progress, seeds: false)
          boot_existing(record)
          reconcile_guest(record)
          lifecycle_result(record.fetch('hostname'), :running, changed: true)
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Invalidate pending lifecycle work and interrupt the native instance before waiting for its resource phase.
      def stop(name:)
        mutate(destructive: true) do
          record = fetch_vm(name)
          cancel_lifecycle(record)
          changed = record['pid'] && @qemu.stop(record, immediate: true)
          instance_phase(record) do
            cancel_lifecycle(record)
            load_state
            record = fetch_vm(name)
            stopped = @qemu.stop(record, immediate: true)
            changed = !!(stopped || changed)
            @peer.stop(record)
            record['state'] = 'stopped'
            record['pid'] = nil
            save
            lifecycle_result(record.fetch('hostname'), :stopped, changed: changed)
          end
        end
      end

      def destroy(name:)
        Infrastructure::Cleanup.new(context: context, runner: @runner, runtime: @runtime,
                                    progress: @progress).node(name)
      end

      def puppet(name:)
        mutate(availability: false) do
          record = running_vm(name)
          @progress.stage(30, 'Running Puppet in VM...')
          puppet_run(record)
        end
      end

      def shell(name:)
        interactive_vm(name) { |record| @guest.shell(record) }
      end

      def console(name:)
        interactive_vm(name) { |record| @qemu.console(record) }
      end

      def exec(name:, arguments:, timeout: nil, output: $stdout, error: $stderr)
        DiagnosticCommand.validate!(arguments, timeout)
        interactive_vm(name) do |record|
          @guest.stream(record, arguments, timeout: timeout, output: output, error: error)
        end
      end

      def ssh(name:, user: nil, identity: nil, port: nil)
        client, record = mutate do
          current = booted_vm(name)
          ssh = ::Empeira::VM::SystemSSH.new(context: context, runner: @runner, runtime: @runtime,
                                             qemu: @qemu, store: @store)
          ssh.prepare(current, user: user, identity: identity, port: port)
        end
        Execution::Terminal.with_interrupts do
          @progress.streaming { client.session(record, user: user, identity: identity) }
        end
      end

      def logs(name:)
        load_state
        record = fetch_vm(name)
        path = @qemu.serial_log(record.fetch('hostname'))
        raise Error, 'VM serial log is unavailable' unless path.file?

        @runner.stream('tail', arguments: ['-n', '200', '-f', path.to_s])
      end

      private

      def interactive_vm(name)
        record = mutate do
          booted_vm(name)
        end
        Execution::Terminal.with_interrupts { @progress.streaming { yield record } }
      end

      def boot_existing(record)
        resume_vm(record)
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Retained VM restart has ordered, visible milestones.
      def resume_vm(record)
        @progress.stage(20, 'Checking retained VM storage...')
        overlay, seed = existing_storage(record)
        @progress.stage(30, 'Checking VM network prerequisites...')
        @peer.preflight(@state)
        @progress.stage(40, 'Preparing VM network...')
        @peer.prepare_image
        instance_phase(record) do
          @peer.prepare(record, @state)
          attachment = Network::Peer::Attachment.new(backend: @peer, record: record, state: @state)
          begin
            @progress.stage(55, 'Starting virtual machine...')
            record['pid'] = @qemu.launch(record: record, overlay: overlay, seed: seed, network: attachment)
          ensure
            save if record['pid']
          end
        end
        @progress.stage(80, 'Waiting for VM management readiness...')
        @guest.wait(record, progress: @progress)
        record['state'] = 'running'
        save
        @progress.stage(95, 'Virtual machine ready.')
      end

      def existing_storage(record)
        ::Empeira::VM::Management.validate!(record)
        base = base_for(record)
        unless base.file? && !base.symlink? &&
               OpenSSL::Digest::SHA256.file(base).hexdigest == record.dig('base_image', 'checksum')
          raise Error, 'Pinned VM base image is missing or corrupt; preserve the overlay and restore the cache'
        end

        overlay = @disk.verify!(hostname: record.fetch('hostname'), base: base)
        seed = vm_directory(record).join('seed.iso')
        raise Error, 'VM cloud-init seed is missing; preserve the node for recovery' unless seed.file?

        [overlay, seed]
      end

      def running_vm(name)
        record = booted_vm(name)
        unless record['provisioned']
          raise Error,
                'VM bootstrap is incomplete; inspect logs or shell before recreating it'
        end

        record
      end

      def booted_vm(name)
        record = fetch_vm(name)
        unless @qemu.running?(record)
          raise Error, "VM #{record.fetch('hostname')} is stopped; run empeira node start #{record.fetch('hostname')}"
        end

        record
      end

      def vm_directory(record)
        context.locations.workspace(context.workspace).join('vms', record.fetch('hostname'))
      end
    end
  end
end
