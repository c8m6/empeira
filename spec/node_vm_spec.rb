# frozen_string_literal: true

require_relative 'support/service_runtime'
require_relative 'support/command_mock_guest'
require_relative 'support/vm_network_guest'

class VMRuntimeFixture < ServiceRuntime
  def check_available!; end

  def architecture
    'amd64'
  end
end

RSpec.describe Empeira::Node::VM do
  include CommandMockGuest
  include RuntimeProxyFixture

  let(:runtime) { VMRuntimeFixture.new }
  let(:app) do
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
  let(:identity) do
    Empeira::Images::Identity.new(distribution: 'ubuntu', version: '24.04', architecture: 'amd64',
                                  source: 'https://example.invalid/base.qcow2', revision: 'test',
                                  checksum: Digest::SHA256.hexdigest('base'))
  end
  let(:request) do
    Empeira::Node::RunRequest.from_config(hostname: 'vm-host', provider: 'vm', config: app.context.configuration)
  end

  before do
    definition = Empeira::Infrastructure::Definition.new(context: app.context)
    runtime.networks[definition.network.backend_name] = Empeira::Network::Resource.new(
      id: 'network-id', name: definition.network.backend_name, labels: definition.network.labels,
      isolated: true, attachment_count: 0
    )
    store.with_lock do
      store.write('schema_version' => 2, 'workspace' => app.context.workspace.id, 'runtime' => 'podman',
                  'resources' => { 'network' => { 'id' => 'network-id', 'name' => definition.network.backend_name,
                                                  'logical_identity' => definition.network.identity } },
                  'definition' => definition.metadata, 'fingerprint' => definition.fingerprint,
                  'component_fingerprints' => definition.component_fingerprints,
                  'peer_network' => { 'subnet' => '10.203.20.0/24' },
                  'created_at' => Time.now.utc.iso8601, 'reconciled_at' => Time.now.utc.iso8601)
      allow(Empeira::ControlPlane::Health).to receive(:new).and_return(
        instance_double(Empeira::ControlPlane::Health, wait: nil, ready?: true)
      )
      allow(Empeira::Runtime::MountProbe).to receive(:new).and_return(
        instance_double(Empeira::Runtime::MountProbe, verify: nil)
      )
      Empeira::ControlPlane::Controller.new(context: app.context, runtime: runtime, store: store).up
    end
    prepare_vm_components
  end

  after do
    cleanup_runtime_proxy_guests
    runtime.cleanup_runtime_proxy_guests
  end

  def prepare_vm_components
    prepare_image_components
    prepare_disk_component
    prepare_guest_components
    prepare_process_component
    prepare_certificates
    proxy = instance_double(Empeira::Network::BootstrapProxy, preflight!: nil, start: 32_003, cleanup: nil,
                                                              url: 'http://bootstrap:synthetic@10.203.20.132:3128')
    allow(Empeira::Network::BootstrapProxy).to receive(:new).and_return(proxy)
  end

  it 'keeps failed initial VM guest reconciliation incomplete before allowing fast Puppet runs' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    expect(provider).to receive(:reconcile_guest).and_raise(Empeira::Error, 'guest reconciliation failed')
    expect(provider.instance_variable_get(:@guest)).not_to receive(:stream)
    expect { provider.run(request) }.to raise_error(Empeira::Error, /guest reconciliation failed/)
    expect(store.load.dig('nodes', request.hostname, 'provisioned')).to be(false)
    expect { provider.puppet(name: request.hostname) }.to raise_error(Empeira::Error, /incomplete/)
  end

  it 'streams Puppet without server readiness, guest reconciliation or VM preflight' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    provider.run(request)
    runtime.services.delete('server')
    expect(runtime).not_to receive(:check_available!)
    expect(runtime).not_to receive(:inspect_service)
    expect(provider).not_to receive(:reconcile_guest)
    expect(provider.instance_variable_get(:@guest)).not_to receive(:run)
    expect(provider.instance_variable_get(:@disk)).not_to receive(:verify!)
    expect(engine).not_to receive(:preflight!)
    expect(provider.instance_variable_get(:@guest)).to receive(:stream).twice.and_return(
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 2, timed_out: false)
    )
    2.times { expect(provider.puppet(name: request.hostname).exit_status).to eq(2) }
    expect(store.load.dig('nodes', request.hostname, 'last_puppet_exit')).to eq(2)
  end

  it 'starts Puppet with the normal proxy inside the privileged guest command' do
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('proxy' => { 'enabled' => true, 'global' => ['packages.example'] }))
    context = app.context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
    store.with_lock { Empeira::ControlPlane::Controller.new(context: context, runtime: runtime, store: store).up }
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: context, runner: app.runner, backend: engine, runtime: runtime)
    expect(provider.instance_variable_get(:@guest)).to receive(:stream).with(
      anything, array_including('env', 'HTTP_PROXY=http://proxy.empeira.internal:3128',
                                'https_proxy=http://proxy.empeira.internal:3128', Empeira::Node::Certificates::PUPPET)
    ).and_return(Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false))
    provider.run(request)
  end

  it 'creates a VM with normal proxy enabled and an explicit IPv4 direct-egress destination' do
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('proxy' => { 'enabled' => true },
                         'network' => { 'egress' => [{ 'ip' => '192.0.2.20', 'ports' => [443] }] }))
    context = app.context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
    store.with_lock { Empeira::ControlPlane::Controller.new(context: context, runtime: runtime, store: store).up }
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: context, runner: app.runner, backend: engine, runtime: runtime)
    expect(provider.run(request).changed).to be(true)
    expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(true)
    expect(store.load.dig('nodes', 'vm-host', 'runtime_proxy', 'current', 'direct')).to include('192.0.2.20')
  end

  it 'preserves unexpected error metadata and its original backtrace when retaining a VM' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    original = nil
    allow(provider.instance_variable_get(:@agent)).to receive(:ensure_installed) do
      {}.fetch('synthetic-missing-key')
    rescue KeyError => e
      original = e
      raise
    end
    expect { provider.run(request) }.to raise_error(KeyError) { |error|
      expect(error.key).to eq('synthetic-missing-key')
      expect(error.backtrace.first).to eq(original.backtrace.first)
      expect(error.cause).to eq(original)
      expect(error.message).to include('retained for diagnosis', 'empeira node destroy vm-host')
    }
    expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
  end

  context 'with VM interface rules' do
    let(:devices) { { 'ens192' => { 'network' => '192.0.2.10/32', 'vlan_id' => 123 } } }
    let(:network_guest) { VMNetworkGuest.new }
    let(:engine) { instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img') }
    let(:app) do
      write_vm_interfaces(devices)
      super()
    end
    let(:provider) { described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime) }

    def write_vm_interfaces(definitions)
      rules = definitions.empty? ? [] : [{ 'hosts' => ['VM-*'], 'devices' => definitions }]
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('vm' => { 'disk' => 32, 'interfaces' => rules }))
    end

    before do
      ssh = provider.instance_variable_get(:@guest)
      arguments = satisfy do |list|
        %w[ip modprobe].include?(list.first) || list.first == '/opt/puppetlabs/bin/facter' ||
          list.first(2) == %w[test -d]
      end
      allow(ssh).to receive(:run).with(anything, arguments) { |record, list| network_guest.run(record, list) }
    end

    it 'verifies interfaces after agent installation and before enrollment and the first catalog' do
      agent = provider.instance_variable_get(:@agent)
      expect(agent).to receive(:ensure_installed) { expect(network_guest.links).not_to have_key('ens192') }
      expect(provider.instance_variable_get(:@guest)).to receive(:stream) do
        expect(network_guest.links.dig('ens192', 'linkinfo', 'info_data', 'id')).to eq(123)
        expect(network_guest.commands).to include(['/opt/puppetlabs/bin/facter', 'networking', '--json'])
        network_guest.result('')
      end
      expect(provider.run(request).changed).to be(true)
      expect(store.load.dig('nodes', 'vm-host', 'network_interfaces', 'devices', 'ens192',
                            'definition')).to eq(devices['ens192'])
    end

    it 'verifies disk growth before packages, interfaces, enrollment and the first catalog' do
      ssh = provider.instance_variable_get(:@guest)
      growth = Empeira::VM::RootDisk.new(guest: ssh)
      packages = instance_double(Empeira::Node::PackageBootstrap, required?: true)
      allow(Empeira::Node::PackageBootstrap).to receive(:new).and_return(packages)
      expect(growth).to receive(:verify!).with(hash_including('hostname' => 'vm-host'), size_gib: 32).ordered
      expect(packages).to receive(:run).with(proxy_url: /bootstrap/).ordered do
        expect(network_guest.links).not_to have_key('ens192')
      end
      expect(provider.instance_variable_get(:@agent)).to receive(:ensure_installed).ordered
      certificates = Empeira::Node::Certificates.new
      expect(certificates).to receive(:enroll).ordered do
        expect(network_guest.links.dig('ens192', 'linkinfo', 'info_data', 'id')).to eq(123)
        expect(network_guest.commands).to include(['/opt/puppetlabs/bin/facter', 'networking', '--json'])
      end
      expect(ssh).to receive(:stream).ordered.and_return(network_guest.result(''))
      expect(provider.run(request).changed).to be(true)
      expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(true)
    end

    it 'blocks packages and interface reconciliation when root growth fails on the combined configuration' do
      ssh = provider.instance_variable_get(:@guest)
      growth = Empeira::VM::RootDisk.new(guest: ssh)
      allow(growth).to receive(:verify!).and_raise(Empeira::Error, 'VM root filesystem has not grown')
      packages = instance_double(Empeira::Node::PackageBootstrap, required?: true)
      allow(Empeira::Node::PackageBootstrap).to receive(:new).and_return(packages)
      expect(packages).not_to receive(:run)
      expect(provider.instance_variable_get(:@agent)).not_to receive(:ensure_installed)
      expect(Empeira::Node::Certificates.new).not_to receive(:enroll)
      expect(ssh).not_to receive(:stream)
      expect { provider.run(request) }.to raise_error(Empeira::Error, /root filesystem.*retained for diagnosis/m)
      expect(network_guest.commands).to be_empty
      expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
      expect { provider.start(name: 'vm-host') }.to raise_error(Empeira::Error, /incomplete/)
      expect { provider.puppet(name: 'vm-host') }.to raise_error(Empeira::Error, /incomplete/)
    end

    it 'restores after start, reconciles running nodes through the node service, and removes changed rules' do
      provider.run(request)
      provider.stop(name: 'vm-host')
      %w[ens192 empeira-vlan].each do |name|
        network_guest.links.delete(name)
        network_guest.addresses.delete(name)
        network_guest.routes.reject! { |route| route['dev'] == name }
      end
      provider.start(name: 'vm-host')
      expect(network_guest.links).to have_key('ens192')
      write_vm_interfaces('dummy1' => { 'network' => '198.51.100.10/24' })
      context = app.context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
      service = Empeira::Node::Service.new(context: context, runner: app.runner)
      expect(service.reconcile(state: store.load)).to be(true)
      expect(network_guest.links).to have_key('dummy1')
      expect(network_guest.links).not_to have_key('ens192')
      expect(service.reconcile(state: store.load)).to be(false)
      write_vm_interfaces({})
      context = context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
      expect(Empeira::Node::Service.new(context: context, runner: app.runner).reconcile(state: store.load)).to be(true)
      expect(network_guest.links).not_to have_key('dummy1')
    end

    it 'retains an incomplete first boot and blocks the first Puppet run after a Facter failure' do
      network_guest.facter_output = '{}'
      expect(provider.instance_variable_get(:@guest)).not_to receive(:stream)
      expect { provider.run(request) }.to raise_error(Empeira::Error, /Facter.*retained/m)
      expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
    end

    it 'rejects conflicting rules before downloads, reservation or launch' do
      conflicting = [{ 'hosts' => ['*'], 'devices' => devices },
                     { 'hosts' => ['vm-*'], 'devices' => { 'ens192' => { 'network' => '192.0.2.11/32' } } }]
      config = Empeira::Configuration::Merge.call(app.context.configuration,
                                                  { 'vm' => { 'interfaces' => conflicting } })
      provider.instance_variable_set(:@context, app.context.with(configuration: config))
      expect(provider.instance_variable_get(:@cache)).not_to receive(:fetch)
      expect(provider.instance_variable_get(:@qemu)).not_to receive(:launch)
      expect { provider.run(request) }.to raise_error(Empeira::ConfigurationError, /interface ens192.*conflicts/)
      expect(store.load.fetch('nodes', {})).to eq({})
    end
  end

  context 'with global bootstrap packages' do
    let(:app) do
      packages = { 'install' => { 'default' => ['git'] }, 'remove' => { 'default' => [] } }
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('bootstrap' => { 'packages' => packages }))
      super()
    end

    it 'uses the shared package bootstrap before the first VM Puppet catalog' do
      packages = instance_double(Empeira::Node::PackageBootstrap, required?: true)
      allow(Empeira::Node::PackageBootstrap).to receive(:new).and_return(packages)
      ssh = vm_guest(app)
      events = []
      apt = instance_double(Empeira::Node::AptConfiguration)
      allow(Empeira::Node::AptConfiguration).to receive(:new).and_return(apt)
      expect(apt).to receive(:preserve).ordered do |&bootstrap|
        bootstrap.call
        events << :apt_restored
      end
      expect(packages).to(receive(:run).with(proxy_url: /bootstrap/).ordered do
        events << :packages
      end)
      result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      expect(ssh).to receive(:stream).ordered do
        events << :puppet
        result
      end
      engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
      provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
      proxy = provider.instance_variable_get(:@bootstrap_proxy)
      qemu = provider.instance_variable_get(:@qemu)
      allow(qemu).to receive(:launch) do
        events << :vm_booted
        12_345
      end
      growth = Empeira::VM::RootDisk.new(guest: ssh)
      allow(growth).to receive(:verify!) { events << :disk_verified }
      allow(proxy).to receive(:start) { events << :bootstrap_proxy }
      allow(proxy).to receive(:cleanup) { events << :proxy_cleanup }
      provider.run(request)
      expect(events.first(7)).to eq(
        %i[vm_booted disk_verified bootstrap_proxy packages apt_restored proxy_cleanup puppet]
      )
    end

    it 'retains an incomplete VM and blocks package installation and Puppet after failed root growth' do
      engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
      provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
      ssh = provider.instance_variable_get(:@guest)
      growth = Empeira::VM::RootDisk.new(guest: ssh)
      allow(growth).to receive(:verify!).and_raise(Empeira::Error, 'VM root filesystem has not grown')
      expect(provider.instance_variable_get(:@agent)).not_to receive(:ensure_installed)
      expect(ssh).not_to receive(:stream)
      packages = instance_double(Empeira::Node::PackageBootstrap, required?: true)
      allow(Empeira::Node::PackageBootstrap).to receive(:new).and_return(packages)
      expect(packages).not_to receive(:run)
      expect { provider.run(request) }.to raise_error(Empeira::Error, /root filesystem.*retained for diagnosis/m)
      expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
      expect { provider.puppet(name: 'vm-host') }.to raise_error(Empeira::Error, /incomplete/)
    end

    it 'does not run Puppet and cleans up bootstrap access when APT restoration fails' do
      apt = instance_double(Empeira::Node::AptConfiguration)
      allow(Empeira::Node::AptConfiguration).to receive(:new).and_return(apt)
      allow(apt).to receive(:preserve).and_raise(
        Empeira::Error,
        'Cannot restore and verify the base image APT configuration; Puppet was not run. Node retained for diagnosis'
      )
      engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
      provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
      proxy = provider.instance_variable_get(:@bootstrap_proxy)
      expect(proxy).to receive(:cleanup).at_least(:once)
      expect(provider.instance_variable_get(:@guest)).not_to receive(:stream)

      expect { provider.run(request) }.to raise_error(Empeira::Error, /APT configuration.*Puppet was not run/)
      expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
    end
  end

  context 'with the Puppet repository method' do
    let(:app) do
      config = { 'bootstrap' => { 'packages' => { 'install' => { 'default' => ['git'] } } } }
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
      super()
    end

    it 'installs base packages before the shared agent installer and the first catalog' do
      events = []
      packages = instance_double(Empeira::Node::PackageBootstrap, required?: true)
      allow(Empeira::Node::PackageBootstrap).to receive(:new).and_return(packages)
      expect(packages).to receive(:run).with(proxy_url: /bootstrap/) { events << :packages }
      engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
      provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
      agent = provider.instance_variable_get(:@agent)
      ssh = provider.instance_variable_get(:@guest)
      expect(agent).to receive(:ensure_installed) { events << :agent }
      allow(ssh).to receive(:stream) do
        events << :puppet
        Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      end

      provider.run(request)
      expect(events).to eq(%i[packages agent puppet])
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Build the complete synthetic image boundary.
  def prepare_image_components
    base = app.context.locations.image(identity).join('base.qcow2')
    FileUtils.mkdir_p(base.dirname)
    File.write(base, 'base')
    image = Empeira::VM::ImageSource::Image.new(identity: identity, url: identity.source, filename: 'base.qcow2')
    source = instance_double(Empeira::VM::ImageSource, resolve: image)
    cache = instance_double(Empeira::VM::ImageCache, fetch: base)
    allow(Empeira::VM::ImageSource).to receive(:new).and_return(source)
    allow(Empeira::VM::ImageCache).to receive(:new).and_return(cache)
  end

  # rubocop:disable-next Metrics/AbcSize -- Disk behavior remains observable through real files.
  def prepare_disk_component
    disk = instance_double(Empeira::VM::Disk)
    allow(disk).to receive(:create) do |hostname:, base:, size_gib:|
      expect(size_gib).to eq(app.context.configuration.dig('vm', 'disk'))
      path = app.context.locations.workspace(app.context.workspace).join('vms', hostname, 'disk.qcow2')
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "overlay for #{base}")
      path
    end
    allow(disk).to receive(:verify!) do |hostname:, **|
      app.context.locations.workspace(app.context.workspace).join('vms', hostname, 'disk.qcow2')
    end
    allow(disk).to receive(:remove) do |hostname:, **|
      File.unlink(app.context.locations.workspace(app.context.workspace).join('vms', hostname, 'disk.qcow2'))
    end
    allow(Empeira::VM::Disk).to receive(:new).and_return(disk)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Isolate guest-only execution.
  def prepare_guest_components
    cloud = instance_double(Empeira::VM::CloudInit, validate!: nil, finish: nil)
    allow(cloud).to receive(:prepare) do |record|
      path = app.context.locations.workspace(app.context.workspace).join('vms', record.fetch('hostname'), 'seed.iso')
      File.write(path, 'seed')
      path
    end
    allow(Empeira::VM::CloudInit).to receive(:new).and_return(cloud)
    ssh = instance_double(Empeira::VM::Guest, wait: nil, copy_to: nil)
    success = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    allow(ssh).to receive(:run) do |record, arguments, **|
      proxy_result = runtime_proxy_result(arguments, record.fetch('hostname'))
      next proxy_result if proxy_result
      if arguments == ['stat', '-c', '%a', Empeira::Node::ExternalFact::PATH]
        next Empeira::Execution::Result.new(stdout: "644\n", stderr: '', exit_status: 0,
                                            timed_out: false)
      end
      next success unless arguments == ['cat', Empeira::Node::ExternalFact::PATH]

      Empeira::Execution::Result.new(stdout: Empeira::Node::ExternalFact.content('vm'), stderr: '',
                                     exit_status: 0, timed_out: false)
    end
    allow(ssh).to receive(:stream).and_return(success)
    allow(Empeira::VM::Guest).to receive(:new).and_return(ssh)
    allow(Empeira::VM::RootDisk).to receive(:new).with(guest: ssh)
                                                 .and_return(instance_double(Empeira::VM::RootDisk, verify!: nil))
    agent = instance_double(Empeira::VM::Agent, ensure_installed: nil)
    allow(Empeira::VM::Agent).to receive(:new).and_return(agent)
    peer = instance_double(Empeira::Network::Peer::LinuxPodman, preflight: nil, prepare: nil, stop: nil,
                                                                destroy: nil, healthy?: true, health: {},
                                                                key: 'LinuxPodman',
                                                                system_ssh_command: nil)
    allow(Empeira::Network::Peer::Backend).to receive(:build).and_return(peer)
  end

  # rubocop:disable-next Metrics/AbcSize -- Model process state across start and stop.
  def prepare_process_component
    running = false
    process = instance_double(Empeira::VM::QemuRuntime)
    allow(process).to receive(:launch) do
      running = true
      12_345
    end
    allow(process).to receive(:running?) { running }
    allow(process).to receive(:observed_running?) { running }
    allow(process).to receive(:cleanup)
    allow(process).to receive(:stop) do |record|
      previous = running
      running = false
      previous ? record : nil
    end
    allow(Empeira::VM::QemuRuntime).to receive(:new).and_return(process)
  end

  def prepare_certificates
    certificates = instance_double(Empeira::Node::Certificates, clean: nil)
    allow(certificates).to receive(:enroll) do |_resource, record, &persist|
      record['certificate_key'] = 'b' * 64
      persist.call
    end
    allow(Empeira::Node::Certificates).to receive(:new).and_return(certificates)
  end

  it 'reconciles mocks through VirtIO management before Puppet, on restart and on workspace reconcile' do
    ssh = Empeira::VM::Guest.new
    # The remaining VM guest operations keep the existing synthetic responses.
    mocks = satisfy { |args| args.size == 4 && args[1] == '-e' && args[2].include?('class ManagedFile') }
    allow(ssh).to receive(:run).with(anything, mocks) do |_, args|
      app.runner.run(RbConfig.ruby, arguments: args.drop(1))
    end
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    node = described_class.new(context: mock_context('oc' => mock_definition), runner: app.runner,
                               backend: engine, runtime: runtime)
    expect(ssh).to receive(:stream) do
      expect(File.executable?(mock_definition['path'])).to be(true)
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    end
    node.run(request)
    expect(node.start(name: 'vm-host').changed).to be(false)
    node.stop(name: 'vm-host')
    updated = described_class.new(context: mock_context('oc' => mock_definition.merge('exit_code' => 19)),
                                  runner: app.runner, backend: engine, runtime: runtime)
    store.with_lock { expect(updated.reconcile_all(state: store.load)).to be(false) }
    updated.start(name: 'vm-host')
    expect(app.runner.run(mock_definition['path']).exit_status).to eq(19)
    removed = described_class.new(context: mock_context({}), runner: app.runner, backend: engine, runtime: runtime)
    store.with_lock { expect(removed.reconcile_all(state: store.load)).to be(true) }
    expect(File.exist?(mock_definition['path'])).to be(false)
  end

  it 'retains a failed bootstrap for diagnosis without reporting a ready VM' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    allow(provider.instance_variable_get(:@agent)).to receive(:ensure_installed).and_raise(Empeira::Error,
                                                                                           'bootstrap failed')
    expect { provider.run(request) }.to raise_error(Empeira::Error, /bootstrap failed/)
    expect(store.load.dig('nodes', 'vm-host', 'provisioned')).to be(false)
    expect(provider.list.first['state']).to eq('incomplete')
    expect { provider.start(name: 'vm-host') }.to raise_error(Empeira::Error, /bootstrap is incomplete/)
    expect(provider.destroy(name: 'vm-host').changed).to be(true)
  end

  it 'releases the workspace lock during console access and protects its VM instance until detach' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    provider.run(request)
    qemu = provider.instance_variable_get(:@qemu)
    expect(qemu).to receive(:console) do
      expect { store.with_lock { nil } }.not_to raise_error
      expect(provider.list.first['state']).to eq('running')
      expect { provider.stop(name: 'vm-host') }.to raise_error(Empeira::Infrastructure::Locked)
      expect { provider.destroy(name: 'vm-host') }.to raise_error(Empeira::Infrastructure::Locked)
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    end
    expect(provider.shell(name: 'vm-host')).to be_success
    expect(provider.stop(name: 'vm-host').changed).to be(true)
  end

  it 'allows parallel SSH access to an incomplete running VM using managed defaults' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    allow(provider.instance_variable_get(:@agent)).to receive(:ensure_installed).and_raise(Empeira::Error,
                                                                                           'bootstrap failed')
    expect { provider.run(request) }.to raise_error(Empeira::Error, /bootstrap failed/)
    result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    client = instance_double(Empeira::Node::UserSSH)
    expect(Empeira::Node::UserSSH).to receive(:new).with(
      runner: app.runner, credentials: an_instance_of(Empeira::Node::SSHCredentials), proxy_command: nil,
      default_user: 'empeira', managed_identity: true, home: app.context.locations.home
    ).twice.and_return(client)
    calls = 0
    allow(client).to receive(:session) do |record, **|
      calls += 1
      expect(record['provisioned']).to be(false)
      expect { store.with_lock { nil } }.not_to raise_error
      provider.ssh(name: 'vm-host', user: 'deploy', identity: '/some/key') if calls == 1
      result
    end
    expect(provider.ssh(name: 'vm-host')).to be_success
    expect(calls).to eq(2)
    expect(provider.destroy(name: 'vm-host').changed).to be(true)
  end

  [Interrupt, IOError].each do |error|
    it "releases the VM session guard after console #{error}" do
      engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
      provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
      provider.run(request)
      allow(provider.instance_variable_get(:@qemu)).to receive(:console).and_raise(error)
      expect { provider.shell(name: 'vm-host') }.to raise_error(error)
      expect(provider.stop(name: 'vm-host').changed).to be(true)
    end
  end

  it 'does not install the agent or run Puppet when cloud-init missed the VM fact' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    ssh = provider.instance_variable_get(:@guest)
    allow(ssh).to receive(:run).and_return(
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
    )
    expect(provider.instance_variable_get(:@agent)).not_to receive(:ensure_installed)
    expect(ssh).not_to receive(:stream)
    expect { provider.run(request) }.to raise_error(Empeira::Error, /bootstrap file.*Puppet was not run/)
  end

  it 'does not install the agent when the VM bootstrap file has the wrong mode' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    ssh = provider.instance_variable_get(:@guest)
    allow(ssh).to receive(:run) do |_record, arguments, **|
      stdout = case arguments
               when ['cat', Empeira::Node::ExternalFact::PATH] then Empeira::Node::ExternalFact.content('vm')
               when ['stat', '-c', '%a', Empeira::Node::ExternalFact::PATH] then "600\n"
               else ''
               end
      Empeira::Execution::Result.new(stdout: stdout, stderr: '', exit_status: 0, timed_out: false)
    end
    expect(provider.instance_variable_get(:@agent)).not_to receive(:ensure_installed)
    expect(ssh).not_to receive(:stream)
    expect { provider.run(request) }.to raise_error(Empeira::Error, /bootstrap file.*Puppet was not run/)
  end

  it 'verifies the shared VM payload before agent installation, enrollment and Puppet' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    agent = provider.instance_variable_get(:@agent)
    ssh = provider.instance_variable_get(:@guest)
    certificates = Empeira::Node::Certificates.new
    bootstrap = Empeira::Node::VMBootstrap.new(guest: ssh)
    allow(Empeira::Node::VMBootstrap).to receive(:new).and_return(bootstrap)
    expect(bootstrap).to receive(:verify).ordered.and_call_original
    expect(agent).to receive(:ensure_installed).ordered
    expect(certificates).to receive(:enroll).ordered do |_resource, record, &persist|
      record['certificate_key'] = 'b' * 64
      persist.call
    end
    expect(ssh).to receive(:stream).ordered.and_return(
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    )
    provider.run(request)
  end

  it 'reserves a shared hostname, retains the overlay on stop, and removes only the owned overlay on destroy' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    expect(provider.run(request).changed).to be(true)
    record = store.load.dig('nodes', 'vm-host')
    expect(record).to include('provider' => 'vm', 'engine' => 'qemu', 'accelerator' => 'kvm',
                              'network' => "#{app.context.workspace.id}:environment", 'state' => 'running')
    expect(provider.list.first).to include('state' => 'running', 'runtime' => 'qemu')
    expect { provider.run(request) }.to raise_error(Empeira::Providers::AlreadyExists)
    container = Empeira::Node::Container.new(context: app.context, runner: app.runner, backend: runtime)
    expect { container.run(request.with(provider: 'container')) }
      .to raise_error(Empeira::Providers::AlreadyExists)
    expect(container.list).to be_empty
    expect(provider.stop(name: 'vm-host').changed).to be(true)
    expect(provider.list.first['state']).to eq('stopped')
    overlay = app.context.locations.workspace(app.context.workspace).join(record.fetch('overlay'))
    expect(overlay).to exist
    expect(provider.instance_variable_get(:@disk)).not_to receive(:create)
    expect(Empeira::VM::RootDisk).not_to receive(:new)
    changed = Empeira::Configuration::Merge.call(app.context.configuration, { 'vm' => { 'disk' => 48 } })
    changed_context = app.context.with(configuration: Empeira::Immutable.deep_freeze(changed))
    provider = described_class.new(context: changed_context, runner: app.runner, backend: engine, runtime: runtime)
    events = []
    progress = Empeira::Progress.new(listener: ->(event) { events << event })
    provider.instance_variable_set(:@progress, progress)
    progress.run('Starting VM...') { expect(provider.start(name: 'vm-host').changed).to be(true) }
    expect(events.select { |event| event.state == :active }.map(&:percent)).to include(20, 30, 40, 55, 80, 95)
    expect(events.last.state).to eq(:complete)
    expect(provider.destroy(name: 'vm-host').changed).to be(true)
    expect(overlay).not_to exist
    expect(app.context.locations.image(identity).join('base.qcow2')).to exist
    expect(store.load.fetch('nodes')).to be_empty
  end

  it 'rejects a same-size corrupted VM base on restart even if its timestamps are preserved' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    provider.run(request)
    provider.stop(name: 'vm-host')
    record = store.load.dig('nodes', 'vm-host')
    overlay = app.context.locations.workspace(app.context.workspace).join(record.fetch('overlay'))
    previous = overlay.binread
    base = app.context.locations.image(identity).join('base.qcow2')
    stat = base.stat
    base.binwrite('bAse')
    File.utime(stat.atime, stat.mtime, base)
    expect(provider.instance_variable_get(:@qemu)).not_to receive(:launch)
    expect { provider.start(name: 'vm-host') }
      .to raise_error(Empeira::Error, /Pinned VM base image is missing or corrupt/)
    expect(overlay.binread).to eq(previous)
    expect(store.load.dig('nodes', 'vm-host', 'state')).to eq('stopped')
  end

  it 'keeps direct console, user SSH and VirtIO management separate' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    provider.run(request)
    expect(provider.instance_variable_get(:@qemu)).to receive(:console).with(hash_including('hostname' => 'vm-host'))
    expect(provider.instance_variable_get(:@guest)).not_to receive(:stream)
    provider.shell(name: 'vm-host')
    client = instance_double(Empeira::Node::UserSSH)
    allow(Empeira::Node::UserSSH).to receive(:new).and_return(client)
    expect(client).to receive(:session).with(hash_including('hostname' => 'vm-host'), user: 'deploy', identity: 'key')
    provider.ssh(name: 'vm-host', user: 'deploy', identity: 'key')
    provider.stop(name: 'vm-host')
    expect { provider.shell(name: 'vm-host') }.to raise_error(Empeira::Error, /node start/)
    expect { provider.ssh(name: 'vm-host') }.to raise_error(Empeira::Error, /node start/)
  end

  it 'does not download, reserve, allocate ports or launch after failed preflight' do
    engine = instance_double(Empeira::VM::Qemu)
    allow(engine).to receive(:preflight!).and_raise(Empeira::UnavailableFeature, 'xorriso missing')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    previous = store.load
    expect(provider.instance_variable_get(:@cache)).not_to receive(:fetch)
    expect(provider.instance_variable_get(:@source)).not_to receive(:resolve)
    expect(provider.instance_variable_get(:@qemu)).not_to receive(:launch)
    expect(provider.instance_variable_get(:@qemu)).not_to receive(:launch)
    expect { provider.run(request) }.to raise_error(Empeira::UnavailableFeature, /xorriso missing/)
    expect(store.load).to eq(previous)
  end

  it 'rejects legacy VM inventory even when gateway creation never completed' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    provider.run(request)
    inventory = store.load
    inventory.delete('peer_network')
    inventory.fetch('nodes').fetch('vm-host').delete('peer')
    path = store.directory.join('infrastructure.json')
    original = JSON.generate(inventory)
    path.write(original)
    expect(provider.instance_variable_get(:@qemu)).not_to receive(:stop)
    expect { provider.destroy(name: 'vm-host') }.to raise_error(Empeira::Infrastructure::StateError, /previous Empeira/)
    expect(path.read).to eq(original)
  end

  it 'revokes bootstrap access on installation failure and includes the exact cleanup command' do
    engine = instance_double(Empeira::VM::Qemu, preflight!: 'kvm')
    provider = described_class.new(context: app.context, runner: app.runner, backend: engine, runtime: runtime)
    proxy = provider.instance_variable_get(:@bootstrap_proxy)
    expect(proxy).to receive(:cleanup)
    allow(provider.instance_variable_get(:@agent)).to receive(:ensure_installed).and_raise(Empeira::Error,
                                                                                           'install failed')
    expect { provider.run(request) }.to raise_error(Empeira::Error, /empeira node destroy vm-host/)
    expect(store.load.fetch('nodes').fetch('vm-host')).not_to have_key('internet')
  end
end
