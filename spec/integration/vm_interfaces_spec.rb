# frozen_string_literal: true

RSpec.describe 'Real VM dummy and VLAN interfaces', :integration do
  let(:engine_name) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  let(:devices) do
    { 'dummy0' => { 'network' => '192.0.2.10/32' },
      'ens192' => { 'network' => '198.51.100.10/24', 'vlan_id' => 123 } }
  end

  def app
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine_name } })
  end

  before do
    skip 'Set EMPEIRA_VM_INTEGRATION=1 on a capable QEMU/KVM or HVF host' unless ENV['EMPEIRA_VM_INTEGRATION'] == '1'

    initialize_project(project)
    write_interfaces(devices)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      $dummy = $facts['networking']['interfaces']['dummy0']['bindings'][0]['address']
      $vlan = $facts['networking']['interfaces']['ens192']['bindings'][0]['address']
      file { '/tmp/empeira-first-interface-facts': content => "${dummy}|${vlan}" }
    PUPPET
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
    Empeira::Runtime.registry.build(engine_name, context: app.context, runner: app.runner).check_available!
  end

  after do
    next unless ENV['EMPEIRA_VM_INTEGRATION'] == '1' && File.directory?(project)

    store = Empeira::Infrastructure::Store.new(context: app.context)
    app.infrastructure.destroy if store.load
  end

  it 'uses regular facts in the first catalog, restores on start, and reconciles edits/removals on up' do
    app.infrastructure.up
    app.run_node(hostname: 'interfaces-vm.example.test', provider: 'vm')
    verify_devices(devices)
    expect(guest(%w[cat /tmp/empeira-first-interface-facts])).to eq('192.0.2.10|198.51.100.10')
    verify_connections
    before = JSON.parse(guest(%w[ip -j -d link show]))
    app.infrastructure.up
    expect(JSON.parse(guest(%w[ip -j -d link show]))).to eq(before)
    app.nodes.stop(name: 'interfaces-vm.example.test')
    app.nodes.start(name: 'interfaces-vm.example.test')
    verify_devices(devices)
    verify_connections

    changed = { 'dummy0' => { 'network' => '192.0.2.11/32' },
                'ens192' => { 'network' => '203.0.113.10/24', 'vlan_id' => 456 } }
    write_interfaces(changed)
    app.infrastructure.up
    verify_devices(changed)
    expect([0, 2]).to include(app.nodes.puppet(name: 'interfaces-vm.example.test').exit_status)
    expect(guest(%w[cat /tmp/empeira-first-interface-facts])).to eq('192.0.2.11|203.0.113.10')
    verify_connections
    write_interfaces({})
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'interfaces-removed': }\n")
    app.infrastructure.up
    names = JSON.parse(guest(%w[ip -j -d link show])).map { |link| link.fetch('ifname') }
    expect(names).not_to include('dummy0', 'ens192', 'empeira-vlan')
    verify_connections
  end

  def write_interfaces(definitions)
    rules = definitions.empty? ? [] : [{ 'hosts' => ['INTERFACES-*.EXAMPLE.TEST'], 'devices' => definitions }]
    config = { 'puppetdb' => { 'enabled' => false }, 'proxy' => { 'enabled' => true },
               'vm' => { 'interfaces' => rules }, 'network' => { 'redirects' => [
                 { 'from' => { 'ip' => '192.0.2.200', 'port' => 8140 },
                   'to' => { 'service' => 'server', 'port' => 8140 } }
               ] } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
  end

  # rubocop:disable-next Metrics/AbcSize -- Resolve the owned instance and use its real managed SSH transport.
  def guest(arguments)
    instance = app
    record = Empeira::Infrastructure::Store.new(context: instance.context).load.dig('nodes',
                                                                                    'interfaces-vm.example.test')
    cloud = Empeira::VM::CloudInit.new(context: instance.context, runner: instance.runner)
    ssh = Empeira::VM::SSH.new(context: instance.context, runner: instance.runner, cloud_init: cloud)
    result = ssh.run(record, arguments)
    expect(result).to be_success, "#{arguments.first} failed: #{result.stderr}"
    result.stdout
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Check independent Linux and Facter observations.
  def verify_devices(definitions)
    links = JSON.parse(guest(%w[ip -j -d link show])).to_h { |entry| [entry.fetch('ifname'), entry] }
    addresses = JSON.parse(guest(%w[ip -j address show])).to_h do |entry|
      [entry.fetch('ifname'), entry.fetch('addr_info')]
    end
    facts = JSON.parse(guest(['/opt/puppetlabs/bin/facter', 'networking',
                              '--json'])).fetch('networking').fetch('interfaces')
    expect(addresses.fetch('empeira-vlan')).to eq([])
    definitions.each do |name, definition|
      link = links.fetch(name)
      expect(link.fetch('flags')).to include('UP')
      expect(link.dig('linkinfo', 'info_kind')).to eq(definition.key?('vlan_id') ? 'vlan' : 'dummy')
      expect(link.dig('linkinfo', 'info_data', 'id')).to eq(definition['vlan_id']) if definition.key?('vlan_id')
      address, prefix = definition.fetch('network').split('/')
      expect(addresses.fetch(name)).to include(hash_including('family' => 'inet', 'local' => address,
                                                              'prefixlen' => prefix.to_i))
      expect(facts.dig(name, 'bindings', 0, 'address')).to eq(address)
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Exercise DNS, normal proxy, gateway redirect and enrolled Puppet TLS.
  def verify_connections
    expect(guest(%w[getent ahostsv4 server.empeira.internal])).to include('server.empeira.internal')
    expect(guest(%w[getent ahostsv4 proxy.empeira.internal])).to include('proxy.empeira.internal')
    expect(guest(['curl', '--silent', '--show-error', '--max-time', '10', '--output', '/dev/null',
                  '--write-out', '%{http_code}', '--proxy', 'http://proxy.empeira.internal:3128', # rubocop:disable Style/FormatStringToken
                  'http://example.invalid'])).to eq('403')
    redirect = app.context.configuration.dig('network', 'redirects', 0, 'from', 'ip')
    guest(['curl', '--silent', '--show-error', '--max-time', '10', '--noproxy', '*', '--fail',
           '--cacert', '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
           '--cert', '/etc/puppetlabs/puppet/ssl/certs/interfaces-vm.example.test.pem',
           '--key', '/etc/puppetlabs/puppet/ssl/private_keys/interfaces-vm.example.test.pem',
           '--resolve', "server.empeira.internal:8140:#{redirect}",
           'https://server.empeira.internal:8140/status/v1/simple'])
    expect([0, 2]).to include(app.nodes.puppet(name: 'interfaces-vm.example.test').exit_status)
  end
end
