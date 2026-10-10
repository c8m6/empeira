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

  it 'grows a new VM disk, uses interface facts in the first catalog, and preserves both through reconciliation' do
    app.infrastructure.up
    app.run_node(hostname: 'interfaces-vm.example.test', provider: 'vm')
    verify_disk_capacity
    expect(guest(%w[git --version])).to include('git version')
    verify_devices(devices)
    expect(guest(%w[cat /tmp/empeira-first-interface-facts])).to eq('192.0.2.10|198.51.100.10')
    verify_connections
    before = JSON.parse(guest(%w[ip -j -d link show]))
    app.infrastructure.up
    expect(JSON.parse(guest(%w[ip -j -d link show]))).to eq(before)
    app.nodes.stop(name: 'interfaces-vm.example.test')
    app.nodes.start(name: 'interfaces-vm.example.test')
    verify_disk_capacity
    verify_devices(devices)
    verify_connections

    changed = { 'dummy0' => { 'network' => '192.0.2.11/32' },
                'ens192' => { 'network' => '203.0.113.10/24', 'vlan_id' => 456 } }
    write_interfaces(changed, size_gib: 48)
    app.infrastructure.up
    verify_disk_capacity
    verify_devices(changed)
    expect([0, 2]).to include(app.nodes.puppet(name: 'interfaces-vm.example.test').exit_status)
    expect(guest(%w[cat /tmp/empeira-first-interface-facts])).to eq('192.0.2.11|203.0.113.10')
    verify_connections
    write_interfaces({}, size_gib: 48)
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'interfaces-removed': }\n")
    app.infrastructure.up
    verify_disk_capacity
    names = JSON.parse(guest(%w[ip -j -d link show])).map { |link| link.fetch('ifname') }
    expect(names).not_to include('dummy0', 'ens192', 'empeira-vlan')
    verify_connections
  end

  def write_interfaces(definitions, size_gib: 32)
    rules = definitions.empty? ? [] : [{ 'hosts' => ['INTERFACES-*.EXAMPLE.TEST'], 'devices' => definitions }]
    config = { 'puppetdb' => { 'enabled' => false }, 'proxy' => { 'enabled' => true },
               'vm' => { 'disk' => size_gib, 'interfaces' => rules },
               'bootstrap' => { 'packages' => { 'install' => { 'default' => ['git'] } } },
               'network' => { 'redirects' => [
                 { 'from' => { 'ip' => '192.0.2.200', 'port' => 8140 },
                   'to' => { 'service' => 'server', 'port' => 8140 } }
               ] } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
  end

  def vm_record
    Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('interfaces-vm.example.test')
  end

  def management_ssh
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
  end

  def guest(arguments)
    result = management_ssh.run(vm_record, arguments)
    expect(result).to be_success, "#{arguments.first} failed: #{result.stderr}"
    result.stdout
  end

  # rubocop:disable-next Metrics/AbcSize -- Observe immutable backing, thin capacity and real guest root growth together.
  def verify_disk_capacity
    overlay = app.context.locations.workspace(app.context.workspace).join(vm_record.fetch('overlay'))
    engine = Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner)
    result = app.runner.run(engine.image_tool, arguments: ['info', '--force-share', '--output=json', overlay.to_s])
    expect(result).to be_success
    metadata = JSON.parse(result.stdout)
    expect(metadata.fetch('virtual-size')).to eq(32 * Empeira::VM::Disk::GIB)
    expect(Digest::SHA256.file(metadata.fetch('backing-filename')).hexdigest)
      .to eq(vm_record.fetch('base_image').fetch('checksum'))
    allocated = File.stat(overlay).blocks * 512
    expect(allocated).to be < 8 * Empeira::VM::Disk::GIB
    Empeira::VM::RootDisk.new(ssh: management_ssh).verify!(vm_record, size_gib: 32)
    RSpec.configuration.reporter.message(
      "Combined VM disk/interfaces (#{engine_name}, allocated #{allocated} bytes): #{guest(%w[df -h /]).strip}"
    )
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
