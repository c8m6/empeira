# frozen_string_literal: true

require_relative 'support/vm_network_guest'

RSpec.describe Empeira::VM::Interfaces do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:record) { { 'hostname' => 'web-one.example.test', 'provider' => 'vm' } }
  let(:state) { { 'peer_network' => { 'subnet' => '10.203.20.0/24' } } }
  let(:guest) { VMNetworkGuest.new }
  let(:saved) { [] }
  let(:devices) do
    { 'dummy0' => { 'network' => '192.0.2.10/32' },
      'ens192' => { 'network' => '198.51.100.10/24', 'vlan_id' => 123 } }
  end

  before { allow(guest).to receive(:run).and_call_original }

  # rubocop:disable-next Metrics/AbcSize -- Exercise the real resolver and reconciler with a stateful guest.
  def reconcile(definitions = devices)
    config = Empeira::Configuration::Merge.call(app.context.configuration,
                                                { 'vm' => { 'interfaces' => [{ 'hosts' => [record.fetch('hostname')],
                                                                               'devices' => definitions }] } })
    config['vm']['interfaces'] = [] if definitions.empty?
    context = app.context.with(configuration: config)
    described_class.new(context: context, record: record, state: state, guest: guest,
                        persist: -> { saved << Marshal.load(Marshal.dump(record)) }).reconcile
  end

  def mutations
    guest.commands.select do |arguments|
      [%w[ip link add], %w[ip link delete], %w[ip address add], %w[ip link set]].include?(arguments.first(3))
    end
  end

  it 'creates real dummy and VLAN types on an unaddressed owned parent, then verifies regular Facter bindings' do
    defaults = guest.routes.select { |route| route['dst'] == 'default' }
    expect(reconcile).to be(true)
    expect(guest.links.dig('dummy0', 'linkinfo', 'info_kind')).to eq('dummy')
    expect(guest.links.dig('ens192',
                           'linkinfo')).to eq('info_kind' => 'vlan',
                                              'info_data' => {
                                                'id' => 123, 'protocol' => '802.1Q'
                                              })
    expect(guest.links.dig('ens192', 'link')).to eq('empeira-vlan')
    expect(guest.addresses['empeira-vlan']).to eq([])
    expect(guest.addresses['ens192']).to include('family' => 'inet', 'local' => '198.51.100.10', 'prefixlen' => 24)
    expect(guest.links.values_at('dummy0', 'ens192', 'empeira-vlan').all? do |link|
      link['flags'].include?('UP')
    end).to be(true)
    expect(guest.routes.select { |route| route['dst'] == 'default' }).to eq(defaults)
    expect(guest.commands.last).to eq(['/opt/puppetlabs/bin/facter', 'networking', '--json'])
    expect(saved.first.dig('network_interfaces', 'devices')).to eq({})
    expect(described_class.valid_inventory?(record.fetch('network_interfaces'))).to be(true)
  end

  it 'makes no guest calls when neither rules nor prior ownership exist' do
    expect(reconcile({})).to be(false)
    expect(guest.commands).to eq([])
    expect(record).not_to have_key('network_interfaces')
  end

  it 'is idempotent and restores only a missing address or administratively down owned link' do
    reconcile
    guest.commands.clear
    expect(reconcile).to be(false)
    expect(mutations).to eq([])
    guest.addresses['dummy0'].clear
    guest.links['dummy0']['flags'] = []
    expect(reconcile).to be(true)
    expect(mutations.map { |arguments| arguments.first(3) }).to eq([%w[ip address add], %w[ip link set]])
  end

  it 'updates IP, prefix and VLAN ID, and permits swapping IDs between owned devices' do
    reconcile
    original = guest.links.dig('ens192', 'ifindex')
    desired = { 'ens192' => { 'network' => '203.0.113.10/32', 'vlan_id' => 456 },
                'ens224' => { 'network' => '198.51.100.10/24', 'vlan_id' => 123 } }
    expect(reconcile(desired)).to be(true)
    expect(guest.links.dig('ens192', 'ifindex')).not_to eq(original)
    expect(guest.links).not_to have_key('dummy0')
    desired['ens192']['vlan_id'] = 123
    desired['ens224']['vlan_id'] = 456
    expect(reconcile(desired)).to be(true)
    expect(guest.links.dig('ens192', 'linkinfo', 'info_data', 'id')).to eq(123)
    expect(guest.links.dig('ens224', 'linkinfo', 'info_data', 'id')).to eq(456)
  end

  it 'changes VLAN to dummy and removes the parent after its last child' do
    reconcile
    expect(reconcile('ens192' => { 'network' => '198.51.100.10/24' })).to be(true)
    expect(guest.links.dig('ens192', 'linkinfo', 'info_kind')).to eq('dummy')
    expect(guest.links).not_to have_key('empeira-vlan')
    expect(reconcile({})).to be(true)
    expect(guest.links.keys).to contain_exactly('eth0')
    expect(record).not_to have_key('network_interfaces')
  end

  it 'restores ephemeral devices after reboot with the retained owner identity' do
    reconcile
    owner = record.dig('network_interfaces', 'token')
    %w[ens192 dummy0 empeira-vlan].each do |name|
      guest.links.delete(name)
      guest.addresses.delete(name)
      guest.routes.reject! { |route| route['dev'] == name }
    end
    expect(reconcile).to be(true)
    expect(record.dig('network_interfaces', 'token')).to eq(owner)
  end

  %w[dummy0 ens192 empeira-vlan].each do |name|
    it "refuses preexisting foreign interface #{name} before any interface mutation" do
      guest.add_foreign(name)
      expect do
        reconcile
      end.to raise_error(Empeira::Providers::OwnershipError,
                         /Host web-one.example.test.*interface #{name}.*vm.interfaces.*foreign/)
      expect(mutations).to eq([])
    end
  end

  it 'never adopts an interface from another workspace or node' do
    reconcile
    guest.links['ens192']['ifalias'] = guest.links['ens192']['ifalias'].sub(app.context.workspace.id, 'f' * 24)
    guest.commands.clear
    expect { reconcile({}) }.to raise_error(Empeira::Providers::OwnershipError, /ens192.*foreign/)
    expect(mutations).to eq([])
  end

  it 'refuses a changed ownership MAC even when the alias is intact' do
    reconcile
    guest.links['ens192']['address'] = '02:00:00:00:00:00'
    guest.commands.clear
    expect { reconcile({}) }.to raise_error(Empeira::Providers::OwnershipError, %r{ens192.*MAC/alias})
    expect(mutations).to eq([])
  end

  it 'refuses a renamed owned link even when its alias is missing' do
    reconcile
    link = guest.links.delete('dummy0')
    link.delete('ifalias')
    link['ifname'] = 'renamed'
    guest.links['renamed'] = link
    guest.addresses['renamed'] = guest.addresses.delete('dummy0')
    guest.commands.clear
    expect { reconcile }.to raise_error(Empeira::Providers::OwnershipError, /renamed.*unrecorded or renamed/)
    expect(mutations).to eq([])
  end

  [true, false].each do |after|
    it "recovers a lost alias-setting outcome #{after ? 'after' : 'before'} the guest mutation" do
      guest.failure = { match: ->(arguments) { arguments.first(3) == %w[ip link set] && arguments[5] == 'alias' },
                        after: after, error: Empeira::VM::Guest::TransportError.new('synthetic lost alias outcome') }
      expect { reconcile }.to raise_error(Empeira::VM::Guest::TransportError, /lost alias outcome/)
      expect(guest.links.fetch('empeira-vlan')).to have_key('address')
      guest.commands.clear
      expect(reconcile).to be(true)
      expect(mutations).not_to include(satisfy do |arguments|
        arguments.first(3) == %w[ip link add] && arguments[4] == 'empeira-vlan'
      end)
      expect(guest.links.dig('empeira-vlan', 'ifalias')).to start_with('empeira:')
    end
  end

  it 'refuses a changed type, parent, foreign address or foreign dependency' do
    reconcile
    guest.links['ens192']['link'] = 'eth0'
    expect { reconcile }.to raise_error(Empeira::Providers::OwnershipError, %r{ens192.*type/parent})
    guest.links['ens192']['link'] = 'empeira-vlan'
    guest.address('dummy0', '203.0.113.10/32')
    expect { reconcile }.to raise_error(Empeira::Providers::OwnershipError, /dummy0.*unowned address/)
    guest.addresses['dummy0'].pop
    guest.routes.reject! { |route| route['dev'] == 'dummy0' && route['dst'].include?('203.0.113') }
    guest.add_foreign('foreign-vlan')
    guest.links['foreign-vlan']['link'] = 'empeira-vlan'
    guest.commands.clear
    expect do
      reconcile({})
    end.to raise_error(Empeira::Providers::OwnershipError, /dependent interface foreign-vlan is foreign/)
    expect(mutations).to eq([])
  end

  %w[10.203.20.101/32 10.203.0.10/16].each do |network|
    it "rejects static workspace overlap #{network}" do
      expect { reconcile('dummy0' => { 'network' => network }) }
        .to raise_error(Empeira::ConfigurationError, /Host web-one.example.test, interface dummy0.*protected route/)
      expect(mutations).to eq([])
    end
  end

  it 'protects addresses and nondefault routes from every table, plus network.redirects' do
    guest.routes << { 'dst' => '203.0.113.0/24', 'dev' => 'eth0', 'table' => 100, 'protocol' => 'static' }
    expect { reconcile('dummy0' => { 'network' => '203.0.113.10/32' }) }
      .to raise_error(Empeira::ConfigurationError, %r{protected route/address 203.0.113.0/24})
    guest.add_foreign('custom', '192.0.2.20/24')
    expect { reconcile }.to raise_error(Empeira::ConfigurationError, %r{protected route/address 192.0.2.20/24})
    redirects = [{ 'from' => { 'ip' => '192.0.2.10', 'port' => 443 },
                   'to' => { 'service' => 'server', 'port' => 8140 } }]
    config = Empeira::Configuration::Merge.call(app.context.configuration,
                                                { 'network' => { 'redirects' => redirects } })
    expect do
      Empeira::VM::InterfaceRoutes.validate_static!(devices, hostname: record['hostname'], config: config, subnet: nil)
    end.to raise_error(Empeira::ConfigurationError, /network.redirects/)
  end

  it 'preserves manual routes on owned devices, including a default route, even when removing definitions' do
    reconcile
    guest.routes << { 'dst' => 'default', 'dev' => 'dummy0', 'protocol' => 'static' }
    guest.commands.clear
    expect { reconcile({}) }.to raise_error(Empeira::Providers::OwnershipError, /dummy0.*non-generated route/)
    expect(mutations).to eq([])
  end

  it 'retains intent on a native failure and resumes after inspecting partial state' do
    guest.failure = { match: ->(arguments) { arguments.first(3) == %w[ip address add] } }
    expect do
      reconcile
    end.to raise_error(Empeira::Error, /guest operation failed.*Exit code: 1.*synthetic netlink failure/m)
    expect(record.dig('network_interfaces', 'devices', 'dummy0', 'definition')).to eq(devices['dummy0'])
    expect(guest.links).to have_key('dummy0')
    expect(reconcile).to be(true)
    expect(reconcile).to be(false)
  end

  it 'protects multipath defaults that reference an owned interface through a nexthop' do
    reconcile
    guest.routes << { 'dst' => 'default', 'protocol' => 'static', 'nexthops' => [
      { 'dev' => 'eth0', 'gateway' => '10.203.20.1' }, { 'dev' => 'dummy0' }
    ] }
    guest.commands.clear
    expect { reconcile({}) }.to raise_error(Empeira::Providers::OwnershipError, /dummy0.*non-generated route/)
    expect(mutations).to eq([])
  end

  it 'loads absent guest modules without creating an unowned default dummy0' do
    allow(guest).to receive(:run).with(anything, satisfy { |arguments| arguments.first(2) == %w[test -d] }) do
      guest.result('', status: 1)
    end
    expect(reconcile).to be(true)
    expect(guest.commands).to include(%w[modprobe dummy numdummies=0], %w[modprobe 8021q])
  end

  it 'reports native module failure without creating any devices' do
    allow(guest).to receive(:run).with(anything, %w[test -d /sys/module/dummy]).and_return(guest.result('', status: 1))
    guest.failure = { match: ->(arguments) { arguments.first == 'modprobe' } }
    expect { reconcile }.to raise_error(Empeira::Error, /vm.interfaces: modprobe.*Exit code: 1/m)
    expect(mutations).to eq([])
  end

  it 'rejects malformed observation JSON and verifies activation and default routes after mutations' do
    allow(guest).to receive(:run).with(anything, %w[ip -j -d link show]).and_return(guest.result('{broken'))
    expect { reconcile }.to raise_error(Empeira::Error, /cannot verify guest ip JSON/)
    expect(mutations).to eq([])
  end

  it 'accepts local parent names and verified index observations while rejecting foreign namespaces' do
    reconcile
    link = guest.links.fetch('ens192')
    link.delete('link')
    link['link_index'] = guest.links.dig('empeira-vlan', 'ifindex')
    expect(reconcile).to be(false)
    link['link_netnsid'] = 1
    expect { reconcile }.to raise_error(Empeira::Providers::OwnershipError, /another network/)
  end

  it 'inspects an atomic owner marker after an unknown SSH create outcome and never replays creation' do
    guest.failure = { match: ->(arguments) { arguments.first(3) == %w[ip link add] }, after: true,
                      error: Empeira::VM::Guest::TransportError.new('synthetic lost completion') }
    expect { reconcile }.to raise_error(Empeira::VM::Guest::TransportError, /lost completion/)
    guest.commands.clear
    expect(reconcile).to be(true)
    expect(mutations.count do |arguments|
      arguments.first(3) == %w[ip link add] && arguments[4] == 'empeira-vlan'
    end).to eq(0)
  end

  it 'recovers an interrupted revision after configuration changes again and an unknown deletion outcome' do
    reconcile
    guest.failure = { match: ->(arguments) { arguments.first(3) == %w[ip link delete] }, after: true,
                      error: Empeira::VM::Guest::TransportError.new('synthetic lost deletion') }
    expect { reconcile('dummy0' => { 'network' => '192.0.2.11/32' }) }.to raise_error(Empeira::VM::Guest::TransportError)
    expect(described_class.valid_inventory?(record.fetch('network_interfaces'))).to be(true)
    expect(reconcile('dummy0' => { 'network' => '203.0.113.10/32' })).to be(true)
    expect(record.dig('network_interfaces', 'devices', 'dummy0')).not_to have_key('previous')
    expect(reconcile({})).to be(true)
  end

  it 'fails closed when Facter omits an interface, reports the wrong first binding or returns malformed JSON' do
    ['{}', 'invalid', JSON.generate('networking' => { 'interfaces' => {} })].each do |output|
      guest.facter_output = output
      expect { reconcile }.to raise_error(Empeira::Error, /Facter networking/)
    end
    expect(described_class.valid_inventory?(record.fetch('network_interfaces'))).to be(true)
    guest.facter_output = nil
    expect(reconcile).to be(false)
  end

  it 'rejects corrupt interface inventory instead of granting ownership' do
    expect(described_class.valid_inventory?({})).to be(false)
    reconcile
    record['network_interfaces']['token'] = 'invalid'
    expect(described_class.valid_inventory?(record.fetch('network_interfaces'))).to be(false)
  end
end

RSpec.describe Empeira::Node::Service do
  let(:configuration) { { 'mocks' => { 'commands' => {} }, 'vm' => { 'interfaces' => [] } } }
  let(:context) { instance_double(Empeira::Application::Context, configuration: configuration) }
  let(:providers) { instance_double(Empeira::Providers::Registry) }
  let(:service) { described_class.new(context: context, runner: Empeira::Execution::Runner.new, providers: providers) }

  [true, false].each do |configured|
    it "reconciles shared guest settings and #{configured ? 'configured' : 'removed'} VM interfaces by provider" do
      if configured
        configuration['vm']['interfaces'] = [{ 'hosts' => ['*'],
                                               'devices' => { 'dummy0' => { 'network' => '192.0.2.10/32' } } }]
      end
      record = { 'provider' => 'vm' }
      record['network_interfaces'] = {} unless configured
      state = { 'nodes' => { 'one' => { 'provider' => 'container' }, 'two' => record } }
      vm = instance_double(Empeira::Node::VM)
      container = instance_double(Empeira::Node::Container)
      expect(providers).to receive(:build).with('container', anything).and_return(container)
      expect(container).to receive(:reconcile_all).with(state: state).and_return(false)
      expect(providers).to receive(:build).with('vm', anything).and_return(vm)
      expect(vm).to receive(:reconcile_all).with(state: state).and_return(true)
      expect(service.reconcile(state: state)).to be(true)
    end
  end
end
