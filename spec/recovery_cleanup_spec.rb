# frozen_string_literal: true

require_relative 'support/service_runtime'

RSpec.describe Empeira::Infrastructure::Cleanup do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context, recovery: true) }
  let(:runtime) { ServiceRuntime.new }
  let(:cleanup) { described_class.new(context: app.context, runner: app.runner, runtime: runtime) }
  let(:network) { Empeira::Network::Definition.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new) }
  let(:state) do
    { 'schema_version' => 2, 'workspace' => app.context.workspace.id, 'runtime' => 'podman',
      'resources' => { 'network' => { 'name' => network.backend_name, 'logical_identity' => network.identity,
                                      'id' => 'owned-network' } },
      'nodes' => {}, 'control_plane' => { 'services' => {}, 'volumes' => {}, 'egress' => nil } }
  end

  def add_node(name, id: SecureRandom.hex(12))
    definition = Empeira::Node::Definition.new(hostname: name, workspace: app.context.workspace)
    runtime.services[definition.key] = { 'id' => id, 'name' => definition.name, 'labels' => definition.labels,
                                         'networks' => { network.backend_name => {} }, 'ports' => {} }
    state.fetch('nodes')[name] = { 'hostname' => name, 'provider' => 'container', 'id' => id,
                                   'certificate_key' => 'a' * 64 }
    definition
  end

  def persist
    store.with_lock { store.write(state) }
  end

  before do
    allow(runtime).to receive(:check_available!)
    runtime.networks[network.backend_name] = Empeira::Network::Resource.new(
      name: network.backend_name, id: 'owned-network', labels: network.labels, isolated: true, attachment_count: 0
    )
  end

  [1, 2, 999].each do |version|
    it "removes positively identified resources from inventory schema #{version} without rewriting its schema" do
      state['schema_version'] = version
      add_node('owned.example.test')
      persist
      expect(runtime).not_to receive(:service_exec)
      expect(cleanup.destroy.changed).to be(true)
      expect(store.load).to be_nil
      expect(runtime.services).to be_empty
      expect(runtime.networks).to be_empty
      expect(cleanup.destroy.changed).to be(false)
      expect(store.directory.join('mutation.lock')).to exist
    end
  end

  it 'preserves another node, shared resources and deferred certificate proof on node destroy' do
    selected = add_node('one.example.test')
    other = add_node('two.example.test')
    persist
    files = Empeira::ControlPlane::Files.new(context: app.context)
    FileUtils.mkdir_p(files.directory)
    files.write('hosts', "192.0.2.1 one.example.test one.example.test.empeira.internal\n192.0.2.2 two.example.test\n")
    expect(runtime).not_to receive(:service_exec)
    cleanup.node('one.example.test')
    expect(runtime.services).not_to have_key(selected.key)
    expect(runtime.services).to have_key(other.key)
    expect(runtime.networks).to have_key(network.backend_name)
    expect(store.load.fetch('nodes').keys).to eq(['two.example.test'])
    expect(store.load.dig('retired_certificates', 'one.example.test')).to eq('a' * 64)
    expect(File.read(files.path('hosts'))).to eq("192.0.2.2 two.example.test\n")
    expect(cleanup.node('one.example.test').changed).to be(false)
  end

  it 'continues deleting other owned resources and retains a replaced instance with complete diagnostics' do
    foreign = add_node('foreign.example.test')
    owned = add_node('owned.example.test')
    runtime.services.fetch(foreign.key)['id'] = 'replacement'
    persist
    expect { cleanup.destroy }.to raise_error(Empeira::Error, /foreign.example.test.*ownership.*ID.*Shared network/m)
    expect(runtime.services).to have_key(foreign.key)
    expect(runtime.services).not_to have_key(owned.key)
    expect(store.load.fetch('nodes').keys).to eq(['foreign.example.test'])
    expect(runtime.networks).to have_key(network.backend_name)
  end

  it 'retains unsafe node paths and processes other nodes without following a symlink' do
    unsafe = add_node('unsafe.example.test')
    add_node('owned.example.test')
    persist
    target = Pathname(@directory).join('foreign-data')
    target.mkdir
    target.join('preserve').write('foreign')
    container_root = store.directory.join('containers')
    container_root.mkdir
    File.symlink(target, container_root.join('unsafe.example.test'))
    expect { cleanup.destroy }.to raise_error(Empeira::Error, /Unsafe workspace path/)
    expect(target.join('preserve').read).to eq('foreign')
    expect(runtime.services.keys).to eq([unsafe.key])
    expect(store.load.fetch('nodes').keys).to eq(['unsafe.example.test'])
  end

  it 'recovers only the recorded runtime after configuration changes and a missing repository' do
    add_node('owned.example.test')
    state['runtime'] = 'docker'
    persist
    File.write(File.join(@directory, '.empeira.yaml'), "requirements: {empeira: '>= 999'}\ninvalid: [\n")
    recovered = Empeira::Application.new(project_path: @directory, recovery: true, locations: app.context.locations)
    expect(recovered.context.container_engine).to eq('docker')
    id = recovered.context.workspace.id
    FileUtils.remove_entry(File.join(@directory, '.git'))
    File.unlink(File.join(@directory, '.empeira.yaml'))
    factories = double('recorded runtime factory')
    expect(factories).to receive(:build).with('docker', context: anything, runner: anything).and_return(runtime)
    recovered = Empeira::Application.new(project_path: '/', recovery: true, recovery_path: @directory,
                                         locations: app.context.locations, factories: { runtimes: factories })
    expect(recovered.context.workspace.id).to eq(id)
    expect(recovered.context.project).to be_nil
    recovered.nodes.destroy(name: 'owned.example.test')
    expect(store.load.fetch('nodes')).to be_empty
    expect(runtime.networks).not_to be_empty
  end

  it 'requires an absolute former Git root and preserves the original identity when the path is missing' do
    project = File.join(@directory, 'disposable-control')
    initialize_project(project)
    identity = Empeira::Workspace.new(path: project).id
    expect { Empeira::Workspace.recover('relative/control') }
      .to raise_error(Empeira::ConfigurationError, /absolute former Git root/)
    expect { Empeira::Workspace.recover("/invalid\0path") }
      .to raise_error(Empeira::ConfigurationError, /absolute former Git root/)
    FileUtils.remove_entry(project)
    expect(Empeira::Workspace.recover(project).id).to eq(identity)
    expect { Empeira::Application.new(recovery_path: project) }
      .to raise_error(Empeira::ConfigurationError, /only available for destroy/)
  end

  [nil, 1, 2, 999].each do |layout|
    it "passes stopped or damaged VM ownership to host cleanup regardless of guest layout #{layout.inspect}" do
      state['nodes']['vm.example.test'] = { 'hostname' => 'vm.example.test', 'provider' => 'vm',
                                            'management_layout' => layout, 'ssh_layout' => 3, 'pid' => nil,
                                            'overlay' => 'vms/vm.example.test/disk.qcow2',
                                            'peer' => { 'token' => 'b' * 32 } }
      persist
      removal = instance_double(Empeira::VM::Removal)
      expect(Empeira::VM::Removal).to receive(:new).with(context: app.context, runner: app.runner,
                                                         runtime: runtime, store: anything).and_return(removal)
      expect(removal).to receive(:remove).with(hash_including('management_layout' => layout), anything)
      expect(runtime).not_to receive(:service_exec)
      cleanup.node('vm.example.test')
      expect(store.load.fetch('nodes')).to be_empty
    end
  end

  it 'refuses resource envelopes with foreign ownership before runtime operations' do
    persist
    path = store.directory.join('infrastructure.json')
    path.write(JSON.generate(state.merge('workspace' => 'f' * 24)))
    expect(runtime).not_to receive(:check_available!)
    expect { cleanup.destroy }.to raise_error(Empeira::Infrastructure::StateError, /ownership/)
  end

  it 'retains unknown newer resource groups while cleaning positively identified resources' do
    add_node('owned.example.test')
    state['control_plane']['future_networks'] = { 'new' => { 'id' => 'unknown' } }
    persist
    expect { cleanup.destroy }.to raise_error(Empeira::Error, /Unrecognized control-plane fields.*future_networks/)
    expect(runtime.services).to be_empty
    expect(store.load.dig('control_plane', 'future_networks')).to eq('new' => { 'id' => 'unknown' })
  end
end
