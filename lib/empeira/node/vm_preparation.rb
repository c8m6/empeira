# frozen_string_literal: true

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- VM creation and its ordered first-boot preparation are one workflow.
    module VMPreparation
      def run(request)
        @created_vm = nil
        mutate do
          server = ready_server
          image, accelerator = preflight_vm(request)
          record, overlay, seed = prepare_vm_disk(request, image, accelerator)
          provision_vm(record, overlay, seed, server)
          lifecycle_result(record.fetch('hostname'), :running, changed: true)
        rescue StandardError => e
          report_retained_vm(e)
        end
      end

      private

      def provision_vm(record, overlay, seed, server)
        packages = package_bootstrap(record)
        Network::Gateway.new(context: context, runtime: @runtime, state: @state).phase(record, bootstrap: true)
        boot_vm(record, overlay, seed)
        @bootstrap_proxy.start(@state, @requirements, source: record.fetch('peer').fetch('ip')) if
          @requirements.required? || packages.required?
        finish_vm(record, server, packages)
      ensure
        @bootstrap_proxy.cleanup(@state)
      end

      def report_retained_vm(error)
        raise error unless @created_vm

        name = @created_vm.fetch('hostname')
        message = "#{error.message}\nVM #{name} retained for diagnosis. Cleanup: empeira node destroy #{name}"
        raise error.exception(message), cause: error
      end

      def prepare_vm_disk(request, image, accelerator)
        @progress.stage(20, 'Preparing VM image...')
        base = @cache.fetch(image)
        record = reserve_vm(request, image.identity, accelerator)
        @created_vm = record
        @progress.stage(35, 'Creating overlay and cloud-init seed...')
        overlay = @disk.create(hostname: record.fetch('hostname'), base: base,
                               size_gib: context.configuration.dig('vm', 'disk'))
        [record, overlay, @cloud.prepare(record)]
      end

      def boot_vm(record, overlay, seed)
        @progress.stage(50, 'Connecting VM to managed services...')
        @peer.prepare(record, @state)
        attachment = Network::Peer::Attachment.new(backend: @peer, record: record, state: @state)
        refresh_dns
        @progress.stage(55, 'Starting virtual machine...')
        begin
          record['pid'] = @qemu.launch(record: record, overlay: overlay, seed: seed, network: attachment)
        ensure
          save if record['pid']
        end
        @progress.stage(60, 'Waiting for VM network and bootstrap...')
        verify_vm_boot(record)
      end

      def verify_vm_boot(record)
        @guest.wait(record, progress: @progress)
        ::Empeira::VM::RootDisk.new(guest: @guest).verify!(record, size_gib: context.configuration.dig('vm', 'disk'))
        VMBootstrap.new(guest: @guest).verify(record: record, bootstrap: Bootstrap.new(provider: 'vm'))
        @cloud.finish(record, guest: @guest)
      end

      def finish_vm(record, server, packages)
        @progress.stage(70, 'Installing/configuring Puppet agent...')
        prepare_agent(record, packages)
        reconcile_interfaces(record)
        @progress.stage(85, 'Signing VM certificate...')
        certificate_runtime = ::Empeira::VM::CertificateRuntime.new(runtime: @runtime, guest: @guest, record: record)
        Certificates.new(runtime: certificate_runtime, server: server).enroll({ 'vm' => true }, record) { save }
        reconcile_guest(record)
        record['provisioned'] = true
        record['state'] = 'running'
        save
        @progress.stage(95, 'Running Puppet...')
        puppet_run(record)
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Preserve bootstrap cleanup before runtime activation.
      def prepare_agent(record, packages)
        execute = ->(arguments) { @guest.run(record, arguments, timeout: 300) }
        package_configuration(record, execute).preserve do
          if packages.required?
            @progress.stage(75, 'Bootstrapping packages...')
            packages.run(proxy_url: @bootstrap_proxy.url)
          end
          @agent.ensure_installed(record, requirements: @requirements, proxy_url: @bootstrap_proxy.url)
        end
        PackageSources.verify!(execute: ->(arguments) { @guest.run(record, arguments) })
        @bootstrap_proxy.cleanup(@state)
        record['network_phase'] = 'runtime'
        save
        Network::Gateway.new(context: context, runtime: @runtime, state: @state).phase(record, bootstrap: false)
        refresh_dns
        reconcile_runtime_proxy(record)
        reconcile_interactive_tools(record)
        configure_agent(record)
      end

      def package_configuration(record, execute)
        family = PackageBootstrap::FAMILIES.fetch(record.fetch('os'))
        klass = family == 'debian' ? AptConfiguration : RpmConfiguration
        options = family == 'debian' ? { on_retry: @progress.method(:warning) } : {}
        klass.new(os: record.fetch('os'), execute: execute, **options)
      end

      def package_bootstrap(record)
        PackageBootstrap.new(config: context.configuration.dig('bootstrap', 'packages'), os: record.fetch('os'),
                             execute: ->(arguments) { @guest.run(record, arguments, timeout: 300) },
                             copy: lambda { |source, destination, mode|
                               @guest.copy_to(record, source, destination, mode: mode)
                             },
                             rpm_options: @requirements.rpm_options,
                             progress: @progress.method(:heartbeat))
      end

      def refresh_dns
        plan = ControlPlane::Plan.new(context: context)
        ControlPlane::Discovery.new(plan: plan, runtime: @runtime, state: @state).refresh
      end

      def configure_agent(record)
        { 'certname' => record.fetch('hostname'), 'server' => 'server.empeira.internal',
          'environment' => context.configuration.dig('server', 'environment') }.each do |key, value|
          result = @guest.run(record, [Certificates::PUPPET, 'config', 'set', key, value, '--section', 'main'])
          next if result.success?

          details = Execution::Diagnostics.command(result, operation: "VM agent configuration: #{key}", tool: 'puppet')
          raise Error, "VM agent configuration failed; node retained for diagnosis\n#{details}", cause: nil
        end
      end

      def puppet_run(record)
        result = @progress.streaming do
          @guest.stream(record, RuntimeProxy.command(context, PuppetCommand.arguments))
        end
        record['last_puppet_exit'] = result.exit_status
        save
        return result if [0, 2].include?(result.exit_status)

        raise Error, "Puppet agent failed (exit #{result.exit_status}); VM retained for shell/logs"
      end
    end
  end
end
