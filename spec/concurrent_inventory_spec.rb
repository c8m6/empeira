# frozen_string_literal: true

RSpec.describe 'Concurrent inventory transactions' do
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:store) { Empeira::Infrastructure::Store.new(context: context) }

  # rubocop:disable-next Metrics/AbcSize -- Build one complete valid synthetic inventory envelope for concurrent write tests.
  def inventory
    definition = Empeira::Infrastructure::Definition.new(context: context)
    { 'schema_version' => 2, 'workspace' => context.workspace.id, 'runtime' => 'podman',
      'generation' => 'a' * 32,
      'resources' => { 'network' => { 'id' => 'network-id', 'name' => definition.network.backend_name,
                                      'logical_identity' => definition.network.identity } },
      'definition' => definition.metadata, 'fingerprint' => definition.fingerprint,
      'component_fingerprints' => definition.component_fingerprints,
      'created_at' => Time.now.utc.iso8601, 'reconciled_at' => Time.now.utc.iso8601 }
  end

  def node(id)
    { 'provider' => 'container', 'runtime' => 'podman', 'hostname' => 'node.example.test',
      'architecture' => 'amd64', 'os' => 'ubuntu', 'version' => '26.04', 'image' => 'synthetic:image',
      'id' => "instance-#{id}", 'provisioned' => true, 'certificate_key' => nil,
      'created_at' => Time.now.utc.iso8601, 'last_puppet_exit' => 0,
      'definition' => { 'hostname' => 'node.example.test', 'image' => 'synthetic:image',
                        'mac_address' => "02:00:00:00:00:0#{id}" } }
  end

  before { store.with_lock { store.write(inventory) } }

  it 'merges independent read-modify-write operations instead of replacing other updates' do
    first = Empeira::Infrastructure::Store.new(context: context)
    second = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do
      a = first.load
      second.with_operation do
        b = second.load
        a['retired_certificates'] = { 'a.example.test' => 'a' * 64 }
        b['retired_certificates'] = { 'b.example.test' => 'b' * 64 }
        first.write(a)
        second.write(b)
        expect(b.fetch('retired_certificates').keys).to contain_exactly('a.example.test', 'b.example.test')
      end
    end
    expect(store.load.fetch('retired_certificates').keys).to contain_exactly('a.example.test', 'b.example.test')
  end

  it 'rejects an incarnation replaced before the resource operation begins' do
    store.write(inventory.merge('generation' => 'b' * 32))
    entered = false
    expect do
      store.with_operation(generation: 'a' * 32) { entered = true }
    end.to raise_error(Empeira::Infrastructure::Cancelled)
    expect(entered).to be(false)
    expect(store.load['generation']).to eq('b' * 32)
  end

  it 'preserves record references while merging unrelated node metadata' do
    original = inventory.merge('nodes' => { 'node.example.test' => node(1) })
    store.write(original)
    first = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do |operation|
      state = first.load
      record = state.fetch('nodes').fetch('node.example.test')
      operation.attach(record)
      current = store.load
      current['nodes']['node.example.test']['state'] = 'stopped'
      store.write(current)
      record['last_puppet_exit'] = 2
      first.write(state)
      expect(state['nodes']['node.example.test']).to equal(record)
      expect(record).to include('state' => 'stopped', 'last_puppet_exit' => 2)
    end
  end

  it 'refreshes a resource owner snapshot without replacing its held node reference' do
    store.write(inventory.merge('nodes' => { 'node.example.test' => node(1) }))
    first = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do |operation|
      state = first.load
      record = state.fetch('nodes').fetch('node.example.test')
      operation.attach(record)
      current = store.load
      current['nodes']['node.example.test']['last_puppet_exit'] = 2
      store.write(current)
      operation.refresh(state)
      expect(state['nodes']['node.example.test']).to equal(record)
      expect(record['last_puppet_exit']).to eq(2)
    end
  end

  it 'rejects an old workspace operation after destroy and immediate recreation' do
    first = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do
      state = first.load
      store.with_lock do
        store.clear
        expect { first.load }.to raise_error(Empeira::Infrastructure::Cancelled)
        store.write(inventory.merge('generation' => 'b' * 32))
      end
      state['retired_certificates'] = { 'old.example.test' => 'a' * 64 }
      expect { first.write(state) }.to raise_error(Empeira::Infrastructure::Cancelled)
    end
    expect(store.load['generation']).to eq('b' * 32)
    expect(store.load).not_to have_key('retired_certificates')
  end

  it 'rejects an old node instance after its hostname is reused' do
    store.write(inventory.merge('nodes' => { 'node.example.test' => node(1) }))
    first = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do |operation|
      state = first.load
      record = state['nodes']['node.example.test']
      operation.attach(record)
      current = store.load
      current['nodes']['node.example.test'] = node(2)
      store.write(current)
      record['last_puppet_exit'] = 6
      expect { first.write(state) }.to raise_error(Empeira::Infrastructure::Cancelled)
    end
    expect(store.load['nodes']['node.example.test']).to include('id' => 'instance-2', 'last_puppet_exit' => 0)
  end

  it 'records an explicit native completion even if it matches the original snapshot' do
    store.write(inventory.merge('nodes' => { 'node.example.test' => node(1) }))
    first = Empeira::Infrastructure::Store.new(context: context)
    first.with_operation do |operation|
      state = first.load
      operation.attach(state['nodes']['node.example.test'])
      current = store.load
      current['nodes']['node.example.test']['last_puppet_exit'] = 2
      store.write(current)
      operation.force('nodes', 'node.example.test', 'last_puppet_exit')
      first.write(state)
    end
    expect(store.load['nodes']['node.example.test']['last_puppet_exit']).to eq(0)
  end

  it 'blocks cancelled provisioning updates while allowing observed creation IDs to reach cleanup' do
    first = Empeira::Infrastructure::Store.new(context: context)
    expect do
      first.with_operation do |operation|
        state = first.load
        operation.resource('infrastructure-phase') do
          current = store.load
          current['destroying'] = true
          store.write(current)
          state['control_plane'] = { 'services' => { 'server' => { 'id' => 'created-id' } },
                                     'volumes' => {}, 'egress' => nil }
          first.write(state)
        end
      end
    end.to raise_error(Empeira::Infrastructure::Cancelled)
    expect(store.load.dig('control_plane', 'services', 'server', 'id')).to eq('created-id')
    expect(store.load['destroying']).to be(true)
  end
end
