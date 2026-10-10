# frozen_string_literal: true

require_relative 'support/runtime_execution'

RSpec.describe Empeira::Infrastructure::Service do
  # These examples isolate the existing network/version contracts from service orchestration.
  before do
    plane = instance_double(Empeira::ControlPlane::Controller, up: false, down: false, destroy: nil,
                                                               status: {}, preflight: nil,
                                                               browser: 'https://127.0.0.1:32124/')
    allow(Empeira::ControlPlane::Controller).to receive(:new).and_return(plane)
  end
  let(:runner) { RuntimeExecution.new }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }

  def application(engine: 'podman', project: @directory, **options)
    Empeira::Application.new(project_path: project, runner: runner, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } }, **options)
  end

  def store(app)
    Empeira::Infrastructure::Store.new(context: app.context)
  end

  it 'includes node-resource reconciliation in up under the existing workspace lock' do
    app = application
    nodes = instance_double(Empeira::Node::Service)
    allow(Empeira::Node::Service).to receive(:new).and_return(nodes)
    allow(nodes).to receive(:reconcile) do |state:|
      expect(state['workspace']).to eq(app.context.workspace.id)
      expect { store(app).with_lock { raise 'must remain locked' } }.to raise_error(Empeira::Infrastructure::Locked)
      true
    end
    expect(app.infrastructure.up.changed).to be(true)
    expect(app.infrastructure.up.changed).to be(true)
    allow(nodes).to receive(:reconcile).and_return(false)
    expect(app.infrastructure.up.changed).to be(false)
  end

  it 'persists runtime, resource identity and fingerprints across service/application instances' do
    app = application
    original = app.infrastructure.up.resource
    inventory = store(app).load
    expect(inventory).to include('schema_version' => 2, 'workspace' => app.context.workspace.id, 'runtime' => 'podman')
    expect(inventory.dig('resources', 'network', 'id')).to eq(original.id)
    expect(inventory['fingerprint']).to match(/\A[0-9a-f]{64}\z/)
    expect(application.infrastructure.up.changed).to be(false)
    expect(application.infrastructure.status).to include('Network' => 'isolated', 'Infrastructure' => 'up')
    expect(application.infrastructure.down.changed).to be(true)
    expect(application.infrastructure.down.changed).to be(false)
    expect(store(app).load).to be_nil
  end

  it 'rejects redirect source collisions with a newly allocated subnet before network creation or inventory writes' do
    redirect = { 'from' => { 'ip' => '10.200.30.3', 'port' => 8080 },
                 'to' => { 'service' => 'server', 'port' => 8140 } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('network' => { 'redirects' => [redirect] }))
    allow_any_instance_of(Empeira::Network::Peer::Allocation).to receive(:choose).and_return('10.200.30.0/24')
    app = application
    expect { app.infrastructure.up }.to raise_error(Empeira::ConfigurationError, /collides with the workspace subnet/)
    expect(runner.mutations).to be_empty
    expect(store(app).load).to be_nil
  end

  it 'destroys the owning runtime when project and user configuration are invalid' do
    original = application(engine: 'docker')
    original.infrastructure.up
    inventory = store(original).load
    inventory['control_plane'] = { 'services' => {}, 'volumes' => {}, 'egress' => nil }
    store(original).write(inventory)
    File.write(File.join(@directory, '.empeira.yaml'), "runtime: [broken\n")
    File.write(File.join(@directory, 'user-home', '.empeira.yaml'), "node_defaults: {cpus: 0}\n")

    expect { application(engine: 'podman') }.to raise_error(Empeira::ConfigurationError)
    recovery = application(engine: 'podman', recovery: true)
    expect(recovery.context.container_engine).to eq('docker')
    recovery.infrastructure.destroy
    expect(store(recovery).load).to be_nil
    expect(runner.networks['docker']).to be_empty
  end

  it 'still enforces a valid project version requirement during destroy' do
    File.write(File.join(@directory, '.empeira.yaml'), "requirements: {empeira: '>= 999.0'}\n")
    app = application(recovery: true)
    expect { app.infrastructure.destroy }.to raise_error(Empeira::Error, /version requirement/)
    expect(store(app).directory).not_to exist
  end

  it 'allows destroy with a schema-invalid project configuration and no inventory' do
    File.write(File.join(@directory, '.empeira.yaml'), "node_defaults: {cpus: 0}\n")
    app = application(recovery: true)
    expect { app.infrastructure.destroy }.not_to raise_error
    expect(store(app).load).to be_nil
  end

  it 'rejects unsupported inventory schemas without rewriting state' do
    app = application
    app.infrastructure.up
    inventory = store(app).load.merge('schema_version' => 1)
    path = store(app).directory.join('infrastructure.json')
    original = JSON.generate(inventory)
    File.write(path, original)
    expect { app.infrastructure.up }.to raise_error(Empeira::Infrastructure::StateError, /schema/)
    expect(File.read(path)).to eq(original)
  end

  [nil, 1, 2].each do |version|
    it "rejects incompatible VM SSH layout #{version.inspect} without state changes or resource removal" do
      app = application
      app.infrastructure.up
      inventory = store(app).load
      inventory['peer_network'] = { 'subnet' => '10.203.20.0/24' }
      record = { 'provider' => 'vm', 'hostname' => 'old-vm' }
      record['ssh_layout'] = version if version
      inventory['nodes'] = { 'old-vm' => record }
      path = store(app).directory.join('infrastructure.json')
      original = JSON.generate(inventory)
      File.write(path, original)
      mutations = runner.mutations.dup
      expect { app.infrastructure.up }.to raise_error(Empeira::Error, /Incompatible VM management SSH layout/)
      expect(File.read(path)).to eq(original)
      expect(runner.mutations).to eq(mutations)
    end
  end

  it 'keeps read-only status from creating state directories or taking an exclusive lock' do
    app = application
    expect(app.infrastructure.status['Infrastructure']).to eq('down')
    expect(store(app).directory).not_to exist
    store(app).with_lock { expect(app.infrastructure.status['Infrastructure']).to eq('down') }
  end

  it 'rejects browser for an uninitialized workspace without creating state or probing a runtime' do
    app = application
    expect { app.infrastructure.browser }
      .to raise_error(Empeira::Error, "Workspace is not initialized. Start it with 'empeira up' first.")
    expect(store(app).directory).not_to exist
    expect(runner.calls).to be_empty
  end

  it 'uses the isolated browser lifecycle without network or node reconciliation' do
    app = application
    app.infrastructure.up
    mutations = runner.mutations.dup
    plane = instance_double(Empeira::ControlPlane::Controller)
    allow(Empeira::ControlPlane::Controller).to receive(:new).and_return(plane)
    expect(Empeira::Node::Service).not_to receive(:new)
    expect(plane).to receive(:browser).and_return('https://127.0.0.1:32124/')

    expect(app.infrastructure.browser).to eq('https://127.0.0.1:32124/')
    expect(runner.mutations).to eq(mutations)
  end

  it 'rejects browser when the recorded workspace network is absent without recreating it' do
    app = application
    app.infrastructure.up
    runner.networks['podman'].clear
    mutations = runner.mutations.dup

    expect { app.infrastructure.browser }.to raise_error(
      Empeira::Error,
      "Required workspace network is not running. Start the workspace with 'empeira up' first."
    )
    expect(runner.mutations).to eq(mutations)
  end

  it 'safely recreates a network missing from the runtime' do
    app = application
    old = app.infrastructure.up.resource
    runner.networks['podman'].clear
    expect(app.infrastructure.status['Infrastructure']).to include('missing')
    expect(app.infrastructure.up.resource.id).not_to eq(old.id)
  end

  it 'recovers an owned resource when local state is absent' do
    app = application
    old = app.infrastructure.up.resource
    store(app).clear
    expect(app.infrastructure.status['Infrastructure']).to include('recoverable')
    expect(app.infrastructure.up.resource).to eq(old)
    expect(runner.mutations.count).to eq(1)
  end

  it 'fails on runtime mismatch before probing the newly configured runtime' do
    application.infrastructure.up
    runner.calls.clear
    other = application(engine: 'docker')
    expect { other.infrastructure.up }.to raise_error(Empeira::Error, /belongs to podman/)
    expect { other.infrastructure.down }.to raise_error(Empeira::Error, /belongs to podman/)
    expect(runner.calls).to be_empty
    expect(other.infrastructure.status).to include('Configured runtime' => 'docker', 'Owning runtime' => 'podman')
    expect(runner.calls.map(&:first).uniq).to eq(['podman'])
  end

  it 'isolates two workspaces and preserves the other network and state on down' do
    second = File.join(@directory, 'checkout')
    initialize_project(second)
    apps = [application, application(project: second)]
    resources = apps.map { |app| app.infrastructure.up.resource }
    expect(resources.map(&:name).uniq.size).to eq(2)
    expect(resources.map(&:labels).uniq.size).to eq(2)
    expect(apps.map { |app| store(app).directory }.uniq.size).to eq(2)
    saved = store(apps.last).load
    apps.first.infrastructure.down
    expect(apps.last.infrastructure.status['Infrastructure']).to eq('up')
    expect(store(apps.last).load).to eq(saved)
  end

  %i[timeout error interrupt].each do |failure|
    it "retains runtime ownership and reconciles after #{failure} without a duplicate creation" do
      app = application
      runner.failure = failure
      error = failure == :interrupt ? Interrupt : Empeira::Providers::ExecutionError
      expect { app.infrastructure.up }.to raise_error(error)
      expect(store(app).load['runtime']).to eq('podman')
      expect(app.infrastructure.status['Infrastructure']).to include('recoverable')
      runner.failure = nil
      expect(app.infrastructure.up.changed).to be(false)
      expect(runner.mutations.count).to eq(1)
    end
  end

  it 'keeps recoverable intent when state persistence fails after runtime creation' do
    app = application
    persistent = store(app)
    service = described_class.new(context: app.context, runner: runner, runtimes: Empeira::Runtime.registry,
                                  build_info: Empeira::BuildInfo.new, store: persistent)
    writes = 0
    allow(persistent).to receive(:write).and_wrap_original do |method, *args|
      writes += 1
      raise Empeira::Infrastructure::StateError, 'synthetic write failure' if writes == 2

      method.call(*args)
    end
    expect { service.up }.to raise_error(Empeira::Infrastructure::StateError)
    expect(application.infrastructure.up.changed).to be(false)
    expect(runner.mutations.count).to eq(1)
  end

  it 'does not create runtime resources if the initial ownership intent cannot be persisted' do
    app = application
    persistent = store(app)
    allow(persistent).to receive(:write).and_raise(Empeira::Infrastructure::StateError)
    service = described_class.new(context: app.context, runner: runner, runtimes: Empeira::Runtime.registry,
                                  build_info: Empeira::BuildInfo.new, store: persistent)
    expect { service.up }.to raise_error(Empeira::Infrastructure::StateError)
    expect(runner.mutations).to be_empty
  end

  it 'retains unsafe partial resources for explicit owned cleanup and never reports successful up' do
    runner.isolation = false
    app = application
    expect { app.infrastructure.up }.to raise_error(Empeira::Network::UnsupportedPolicy)
    expect(app.infrastructure.status['Network']).to eq('unsafe isolation')
    expect(app.infrastructure.down.changed).to be(true)
    expect(runner.networks['podman']).to be_empty
  end

  it 'shows stale definitions and requires explicit cleanup instead of automatic replacement' do
    app = application
    app.infrastructure.up
    inventory = store(app).load
    inventory['definition']['revision'] = 0
    inventory['fingerprint'] = Empeira::Infrastructure::Definition.fingerprint(inventory['definition'])
    store(app).write(inventory)
    expect(app.infrastructure.status['Infrastructure fingerprint']).to eq('stale')
    expect { app.infrastructure.up }.to raise_error(Empeira::Error, /stale/)
    expect(runner.mutations.count).to eq(1)
    expect(app.infrastructure.down.changed).to be(true)
  end

  it 'rejects a conflicting persisted resource ID on up and down' do
    app = application
    app.infrastructure.up
    inventory = store(app).load
    inventory['resources']['network']['id'] = 'other-id'
    store(app).write(inventory)
    expect { app.infrastructure.up }.to raise_error(Empeira::Providers::OwnershipError)
    expect { app.infrastructure.down }.to raise_error(Empeira::Providers::OwnershipError)
    expect(runner.mutations.count).to eq(1)
  end

  it 'refuses to forget a recorded resource that was renamed externally' do
    app = application
    app.infrastructure.up
    runner.networks['podman'].values.first['name'] = 'changed-name'
    expect { app.infrastructure.down }.to raise_error(Empeira::Providers::OwnershipError, /different name/)
    expect(store(app).load).not_to be_nil
  end

  it 'reports definition-label drift even when the recorded aggregate fingerprint is current' do
    app = application
    app.infrastructure.up
    runner.networks['podman'].values.first['labels']['io.empeira.definition'] = 'old-definition'
    expect(app.infrastructure.status['Infrastructure fingerprint']).to eq('stale runtime definition')
    expect { app.infrastructure.up }.to raise_error(Empeira::Error, /definition is stale/)
    expect(runner.mutations.count).to eq(1)
    expect(app.infrastructure.down.changed).to be(true)
  end

  it 'does not interpret a broken state symlink as missing inventory' do
    app = application
    persistent = store(app)
    persistent.with_lock do
      File.symlink(persistent.directory.join('missing.json'), persistent.directory.join('infrastructure.json'))
    end
    expect { app.infrastructure.up }.to raise_error(Empeira::Infrastructure::StateError, /symlink/)
    expect(runner.calls).to be_empty
  end

  it 'rejects malformed state instead of treating it as an empty inventory' do
    app = application
    app.infrastructure.up
    path = store(app).directory.join('infrastructure.json')
    File.write(path, '{"schema_version":999}')
    expect { app.infrastructure.up }.to raise_error(Empeira::Infrastructure::StateError)
    expect { app.infrastructure.down }.to raise_error(Empeira::Infrastructure::StateError)
    expect(app.infrastructure.status['Diagnostic']).to include('state schema')
    expect(runner.mutations.count).to eq(1)
  end
  it 'checks local artifacts before runtime mutation without constructing an updater' do
    app = application
    expect(Empeira::Updates::Modules).not_to receive(:new)
    plane = instance_double(Empeira::ControlPlane::Controller)
    allow(Empeira::ControlPlane::Controller).to receive(:new).and_return(plane)
    expect(plane).to receive(:preflight).with(no_args).ordered do
      expect(runner.mutations).to be_empty
      expect(store(app).load).to be_nil
    end
    expect(plane).to receive(:up).with(no_args).ordered do
      expect(runner.mutations.size).to eq(1)
      false
    end
    app.infrastructure.up
  end

  it 'fails missing artifact validation before network mutation' do
    app = application
    plane = instance_double(Empeira::ControlPlane::Controller)
    allow(Empeira::ControlPlane::Controller).to receive(:new).and_return(plane)
    allow(plane).to receive(:preflight).and_raise(Empeira::Error, 'Run: empeira update modules')
    expect(plane).not_to receive(:up)
    expect { app.infrastructure.up }.to raise_error(Empeira::Error, /update modules/)
    expect(runner.mutations).to be_empty
    expect(store(app).load).to be_nil
  end
end
