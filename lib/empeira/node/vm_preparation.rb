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
        Network::Gateway.new(context: context, runtime: @runtime, state: @state, store: @store).phase(record,
                                                                                                      bootstrap: true)
        boot_vm(record, overlay, seed)
        @bootstrap_proxy.start(@state, @requirements, source: record.fetch('peer').fetch('ip')) if
          @requirements.required? || packages.required?
        finish_vm(record, server, packages)
      ensure
        @bootstrap_proxy.cleanup(@state)
      end

      def report_retained_vm(error)
        raise error if error.is_a?(Infrastructure::Cancelled)
        raise error unless @created_vm

        name = @created_vm.fetch('hostname')
        message = "#{error.message}\nVM #{name} retained for diagnosis. Cleanup: empeira node destroy #{name}"
        raise error.exception(message), cause: error
      end

      def prepare_vm_disk(request, image, accelerator)
        @progress.stage(20, 'Preparing VM image...')
        record = reserve_vm_instance(request, image.identity, accelerator)
        @store.operation.attach(record, lifecycle: true)
        @created_vm = record
        base = @cache.fetch(image)
        @progress.stage(35, 'Creating overlay and cloud-init seed...')
        instance_phase(record) do
          overlay = @disk.create(hostname: record.fetch('hostname'), base: base,
                                 size_gib: context.configuration.dig('vm', 'disk'))
          [record, overlay, @cloud.prepare(record)]
        end
      end

      def boot_vm(record, overlay, seed)
        @progress.stage(50, 'Connecting VM to managed services...')
        @peer.prepare_image
        instance_phase(record) do
          @peer.prepare(record, @state)
          attachment = Network::Peer::Attachment.new(backend: @peer, record: record, state: @state)
          refresh_dns
          @progress.stage(55, 'Starting virtual machine...')
          begin
            record['pid'] = @qemu.launch(record: record, overlay: overlay, seed: seed, network: attachment)
          ensure
            save if record['pid']
          end
        end
        @progress.stage(60, 'Waiting for VM network and bootstrap...')
        verify_vm_boot(record)
      end

      def verify_vm_boot(record)
        @guest.wait(record, progress: @progress)
        ::Empeira::VM::RootDisk.new(guest: @guest).verify!(record, size_gib: context.configuration.dig('vm', 'disk'))
        VMBootstrap.new(guest: @guest).verify(record: record, bootstrap: Bootstrap.new(provider: 'vm'))
        record['empeira_fact'] = ExternalFact.fingerprint('vm')
        save
        instance_phase(record) { @cloud.finish(record, guest: @guest) }
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Retain ordered bootstrap, certificate and ready-state milestones around cancellable guest operations.
      def finish_vm(record, server, packages)
        @progress.stage(70, 'Installing/configuring Puppet agent...')
        prepare_agent(record, packages)
        reconcile_interfaces(record)
        @progress.stage(85, 'Signing VM certificate...')
        certificate_runtime = ::Empeira::VM::CertificateRuntime.new(runtime: @runtime, guest: @guest, record: record)
        certificates = Certificates.new(runtime: certificate_runtime, server: server,
                                        guard: @store.operation.method(:check!))
        instance_phase(record) do
          certificates.clean_retired(@state, record.fetch('hostname')) { save } if @state['retired_certificates']
          certificates.enroll({ 'vm' => true }, record) { save }
        end
        reconcile_guest(record)
        instance_phase(record) do
          record['provisioned'] = true
          record['state'] = 'running'
          save
        end
        @store.operation.attach(record)
        @progress.stage(95, 'Running Puppet...')
        InitialPuppetRuns.new(count: context.configuration.dig('node_defaults', 'puppet_runs'), progress: @progress)
                         .run { puppet_run(record, initial: true) }
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
        Network::Gateway.new(context: context, runtime: @runtime, state: @state, store: @store).phase(record,
                                                                                                      bootstrap: false)
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
        ControlPlane::Discovery.new(plan: plan, runtime: @runtime, state: @state, store: @store).refresh
      end

      def configure_agent(record)
        AgentConfiguration.apply(record: record, environment: context.configuration.dig('server', 'environment'),
                                 execute: ->(arguments) { @guest.run(record, arguments) })
      end

      def puppet_run(record, initial: false)
        reconcile_provider_fact(record)
        result = @progress.streaming do
          @guest.stream(record, RuntimeProxy.command(context, PuppetCommand.arguments))
        end
        record_completion(record, result)
        return result if initial || [0, 2].include?(result.exit_status)

        raise Error, "Puppet agent failed (exit #{result.exit_status}); VM retained for shell/logs"
      end
    end
  end
end
