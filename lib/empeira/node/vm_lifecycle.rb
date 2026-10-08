# frozen_string_literal: true

require 'fileutils'

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- Node lifecycle and cleanup share the workspace lock.
    module VMLifecycle
      def start(name:)
        mutate do
          record = fetch_vm(name)
          unless record['provisioned']
            raise Error, 'VM bootstrap is incomplete; inspect logs, then destroy and recreate the node'
          end

          refresh_environment_cache
          if @qemu.running?(record)
            return lifecycle_result(name.downcase, :running, changed: reconcile_command_mocks(record))
          end

          @progress.stage(1, 'Checking VM control-plane readiness...')
          @engine.preflight!(progress: @progress, seeds: false)
          boot_existing(record)
          reconcile_command_mocks(record)
          lifecycle_result(record.fetch('hostname'), :running, changed: true)
        end
      end

      def stop(name:)
        mutate do
          record = fetch_vm(name)
          changed = !!@qemu.stop(record)
          @peer.stop(record)
          record['state'] = 'stopped'
          record['pid'] = nil
          save
          lifecycle_result(record.fetch('hostname'), :stopped, changed: changed)
        end
      end

      def destroy(name:)
        mutate do
          @bootstrap_proxy.cleanup(@state)
          changed = !!remove_vm(name.downcase)
          refresh_dns if changed
          Providers::Result.new(resource: nil, changed: changed)
        end
      end

      def destroy_all(state:)
        load_state(state)
        @runtime.check_available!
        @bootstrap_proxy.cleanup(@state)
        vm_records.each_key { |name| remove_vm(name, certificates: false) }
      end

      def puppet(name:)
        mutate do
          record = running_vm(name)
          ready_server
          @progress.stage(30, 'Running Puppet in VM...')
          puppet_run(record)
        end
      end

      def shell(name:)
        mutate { @qemu.console(booted_vm(name)) }
      end

      def ssh(name:, user: nil, identity: nil)
        mutate do
          record = booted_vm(name)
          credentials = SSHCredentials.new(context: context, runner: @runner, provider: 'vm',
                                           hostname: record.fetch('hostname'))
          UserSSH.new(runner: @runner, credentials: credentials, proxy_command: @peer.ssh_command(record)).session(
            record, user: user, identity: identity
          )
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

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Retained VM restart has ordered, visible milestones.
      def boot_existing(record)
        @progress.stage(20, 'Checking retained VM storage...')
        overlay, seed = existing_storage(record)
        @progress.stage(30, 'Checking VM network prerequisites...')
        @peer.preflight(@state)
        @progress.stage(40, 'Preparing VM network...')
        @peer.prepare(record, @state)
        attachment = Network::Peer::Attachment.new(backend: @peer, record: record, state: @state)
        begin
          @progress.stage(55, 'Starting virtual machine...')
          record['pid'] = @qemu.launch(record: record, overlay: overlay, seed: seed, network: attachment)
        ensure
          save if record['pid']
        end
        @progress.stage(80, 'Waiting for VM SSH readiness...')
        @ssh.wait(record, progress: @progress)
        record['state'] = 'running'
        save
        @progress.stage(95, 'Virtual machine ready.')
      end

      def existing_storage(record)
        base = base_for(record)
        unless base.file? && !base.symlink? &&
               Digest::SHA256.file(base).hexdigest == record.dig('base_image', 'checksum')
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

      def remove_vm(name, certificates: true)
        record = vm_records[name]
        return unless record

        @qemu.stop(record)
        @peer.destroy(record, @state)
        @qemu.cleanup(record)
        clean_vm_certificate(record) if certificates && record['certificate_key']
        remove_vm_disk(record)
        remove_vm_directory(record)
        @nodes.delete(name)
        save
        record
      end

      def clean_vm_certificate(record)
        Certificates.new(runtime: @runtime, server: ready_server).clean(record)
      end

      def remove_vm_disk(record)
        base = base_for(record)
        overlay = vm_directory(record).join('disk.qcow2')
        @disk.remove(hostname: record.fetch('hostname'), base: base) if overlay.exist? || overlay.symlink?
      end

      def remove_vm_directory(record)
        directory = vm_directory(record)
        return unless directory.exist? || directory.symlink?

        FileUtils.remove_entry_secure(directory)
      end

      def vm_directory(record)
        context.locations.workspace(context.workspace).join('vms', record.fetch('hostname'))
      end
    end
  end
end
