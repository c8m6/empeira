# frozen_string_literal: true

RSpec.describe Empeira::ControlPlane::Discovery, :files_only do
  let(:workspace) { Struct.new(:id).new('b' * 24) }
  let(:context) { Struct.new(:workspace).new(workspace) }
  let(:files) { instance_double(Empeira::ControlPlane::Files, hosts: nil, proxy_clients: false) }
  let(:plan) do
    instance_double(Empeira::ControlPlane::Plan, context: context, network: 'owned-network', files: files)
  end
  let(:runtime) { instance_double(Empeira::Runtime::Podman) }
  let(:lock) { instance_double(Empeira::Infrastructure::ResourceLock) }
  let(:state) do
    { 'generation' => 'a' * 32, 'control_plane' => { 'services' => {} },
      'nodes' => { 'node.test' => { 'provider' => 'container', 'hostname' => 'node.test', 'id' => 'first-id',
                                    'definition' => { 'ip' => '172.20.0.96' }, 'network_phase' => 'runtime' } } }
  end
  let(:current) { Marshal.load(Marshal.dump(state)) }
  let(:store) do
    instance_double(Empeira::Infrastructure::Store, resource_lock: lock, load: current, write: nil)
  end
  let(:observed) do
    { 'node.test' => { 'id' => 'first-id', 'networks' => { 'owned-network' => { 'IPAddress' => '172.20.0.96' } } } }
  end
  let(:discovery) { described_class.new(plan: plan, runtime: runtime, state: state, store: store) }

  before { allow(lock).to receive(:synchronize).and_yield }

  it 'reuses verified instance observations while deriving grants from current inventory' do
    current.fetch('nodes').fetch('node.test')['network_phase'] = 'bootstrap'
    expect(runtime).not_to receive(:inspect_services)
    expect(files).to receive(:proxy_clients).with(anything, 'owned-network', nodes: current.fetch('nodes'))
                                            .and_return(false)
    discovery.refresh(services: {}, node_resources: observed)
  end

  it 'reobserves a replaced instance before publishing its current lease' do
    current.fetch('nodes').fetch('node.test').merge!('id' => 'second-id', 'definition' => { 'ip' => '172.20.0.97' })
    expect(runtime).to receive(:inspect_services).with(
      { 'node.test' => an_instance_of(Empeira::Node::Definition) }, expected_ids: { 'node.test' => 'second-id' }
    ).and_return('node.test' => { 'id' => 'second-id' })
    expect(files).to receive(:hosts).with(
      { 'node.test' => { 'networks' => { 'owned-network' => { 'IPAddress' => '172.20.0.97' } } } }, 'owned-network'
    )
    discovery.refresh(services: {}, node_resources: observed)
  end

  it 'never republishes a removed node from cached observations' do
    current.fetch('nodes').clear
    expect(runtime).not_to receive(:inspect_services)
    expect(files).to receive(:hosts).with({}, 'owned-network')
    discovery.refresh(services: {}, node_resources: observed)
  end
end
