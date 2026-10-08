# frozen_string_literal: true

RSpec.describe 'Production peer network contracts' do
  let(:app) do
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end
  let(:record) do
    { 'hostname' => 'vm-one', 'ssh_port' => 32_001, 'mac_address' => '52:54:ab:cd:ef:12',
      'peer' => { 'ip' => '10.203.20.32', 'dns' => '10.203.20.130', 'token' => SecureRandom.hex(16),
                  'adapter_id' => nil, 'backend' => 'DockerAdapter' } }
  end

  it 'allocates disjoint VM and runtime pools and reserves stopped instances' do
    layout = Empeira::Network::Peer::Layout.new('10.203.20.0/24')
    lease = layout.lease({})
    following = layout.lease('stopped-node' => { 'state' => 'stopped', 'peer' => lease })
    expect(lease.fetch('ip')).to eq('10.203.20.32')
    expect(following.fetch('ip')).to eq('10.203.20.33')
    expect(IPAddr.new(layout.container_pool)).not_to include(IPAddr.new(lease.fetch('ip')))
    expect(layout.lease({}).fetch('token')).not_to eq(lease.fetch('token'))
    expect { Empeira::Network::Peer::Layout.new('0.0.0.0/0') }.to raise_error(Empeira::Infrastructure::StateError)
  end

  it 'retries private subnets around known VPN and runtime overlap' do
    runtime = instance_double(Empeira::Runtime::Podman, network_subnets: ['172.16.0.0/12'])
    runner = instance_double(Empeira::Execution::Runner)
    routes = instance_double(Empeira::Platform::Routes, ipv4: ['10.0.0.0/8', '192.168.0.0/24'])
    allow(Empeira::Platform::Routes).to receive(:new).and_return(routes)
    chosen = Empeira::Network::Peer::Allocation.new(context: app.context, runtime: runtime, runner: runner).choose
    expect(chosen).to start_with('192.168.')
    expect(chosen).not_to eq('192.168.0.0/24')
    allow(routes).to receive(:ipv4).and_return(['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'])
    expect { Empeira::Network::Peer::Allocation.new(context: app.context, runtime: runtime, runner: runner).choose }
      .to raise_error(Empeira::Error, /No safe private/)
  end

  it 'keeps Docker adapters isolated with only NET_ADMIN and TUN and no application mounts or ports' do
    backend = Empeira::Network::Peer::DockerAdapter.new(context: app.context, runtime: nil, runner: nil, store: nil)
    backend.instance_variable_set(:@image, Empeira::Network::Peer::AdapterImage.new(context: app.context))
    definition = backend.send(:adapter_definition, record)
    arguments = Empeira::Runtime::ServiceArguments.new(definition).build
    expect(arguments).to include('--cap-drop', 'ALL', '--cap-add', 'NET_ADMIN', '--device', '/dev/net/tun',
                                 '--read-only')
    expect(arguments).not_to include('--privileged', '--publish', '--mount', '--network=host')
    expect(definition.options.fetch('network')).to eq(Empeira::ControlPlane::Plan.new(context: app.context).network)
    expect(definition.options.fetch('sysctls')).to include('net.ipv4.ip_forward' => '0')
  end

  it 'reserves container addresses outside both VM leases and automatic runtime allocation' do
    layout = Empeira::Network::Peer::Layout.new('10.203.20.0/24')
    first = layout.container_lease({})
    expect(first).to eq('10.203.20.96')
    expect(layout.container_lease('stopped' => { 'definition' => { 'ip' => first } })).to eq('10.203.20.97')
    expect(IPAddr.new(layout.container_pool)).not_to include(IPAddr.new(first))
    full = (32..95).to_h { |offset| [offset, { 'peer' => { 'ip' => layout.address(offset) } }] }
    expect { layout.lease(full) }.to raise_error(Empeira::Error, /pool exhausted/)
  end

  it 'rejects observed helper privilege escalation, application mounts and forwarding' do
    config = { 'Privileged' => false, 'ReadonlyRootfs' => true, 'CapAdd' => ['CAP_NET_ADMIN'],
               'CapDrop' => ['ALL'], 'SecurityOpt' => ['no-new-privileges'],
               'Devices' => [{ 'PathOnHost' => '/dev/net/tun', 'PathInContainer' => '/dev/net/tun' }],
               'Sysctls' => { 'net.ipv4.ip_forward' => '0', 'net.ipv6.conf.all.disable_ipv6' => '1' } }
    resource = { 'host_config' => config, 'mounts' => [] }
    expect { Empeira::Network::Peer::HelperSecurity.verify!(resource, privileged_tap: true) }.not_to raise_error
    [{ 'Privileged' => true }, { 'CapAdd' => ['CAP_SYS_ADMIN'] },
     { 'Sysctls' => { 'net.ipv4.ip_forward' => '1' } }].each do |override|
      expect do
        Empeira::Network::Peer::HelperSecurity.verify!(resource.merge('host_config' => config.merge(override)),
                                                       privileged_tap: true)
      end.to raise_error(Empeira::Providers::OwnershipError)
    end
    expect do
      Empeira::Network::Peer::HelperSecurity.verify!(resource.merge('mounts' => [{}]), privileged_tap: true)
    end.to raise_error(Empeira::Providers::OwnershipError)
  end

  it 'rejects ambiguous Podman Machines and never selects a rootful connection' do
    backend = Empeira::Network::Peer::PodmanMachine.new(context: app.context, runtime: nil, runner: nil, store: nil)
    allow(backend).to receive(:command).with('podman', 'machine', 'list', '--format', 'json')
                                       .and_return(JSON.generate([{ 'Name' => 'dev', 'Running' => true }]))
    allow(backend).to receive(:command).with('podman', 'system', 'connection', 'list', '--format', 'json')
                                       .and_return(JSON.generate([{ 'Name' => 'dev-root', 'Default' => true }]))
    expect { backend.send(:select_machine) }.to raise_error(Empeira::Error, /unambiguous/)
    allow(backend).to receive(:command).with('podman', 'info', '--format', 'json')
                                       .and_return(JSON.generate('host' => { 'security' => { 'rootless' => false } }))
    expect { backend.send(:verify_rootless) }.to raise_error(Empeira::Error, /no rootful fallback/)
  end

  it 'refuses a TAP collision even when its name matches a reserved node' do
    backend = Empeira::Network::Peer::LinuxPodman.new(context: app.context, runtime: nil, runner: nil, store: nil)
    record['peer']['backend'] = backend.key
    allow(backend).to receive(:namespace).with('ip', '-j', 'link', 'show')
                                         .and_return(JSON.generate([{ 'ifname' => backend.tap(record) }]))
    expect { backend.prepare(record, {}) }.to raise_error(Empeira::Providers::OwnershipError, /already exists/)
    expect { backend.stop(record) }.to raise_error(Empeira::Error, /still present/)
  end

  it 'refuses to clean up a private channel with a different persisted ownership token' do
    channel = Empeira::Network::Peer::Channel.new(context: app.context, runner: nil, record: record)
    channel.prepare
    path = Pathname(channel.socket).dirname.join('channel.json')
    File.write(path, JSON.generate('token' => 'f' * 32), mode: 'w', perm: 0o600)
    expect { channel.destroy }.to raise_error(Empeira::Providers::OwnershipError, /token changed/)
    expect(path).to exist
  ensure
    File.unlink(path) if path&.file?
    channel&.destroy
  end

  it 'uses a direct TAP only in the selected rootless namespace and keeps management SSH separate' do
    backend = Empeira::Network::Peer::LinuxPodman.new(context: app.context, runtime: nil, runner: nil, store: nil)
    arguments = backend.arguments(record)
    expect(arguments.join(' ')).to include('tap,id=peer,ifname=et', 'script=no,downscript=no')
    expect(arguments.join(' ')).not_to include('guestfwd', 'hostfwd', 'tcg')
    management = Empeira::Network::Peer::Management.new(record).arguments.join(' ')
    expect(management).to include('restrict=on', 'ipv6=off', 'hostfwd=tcp:127.0.0.1:32001-:22')
    expect(management).not_to include('guestfwd', '8140', '3128', ':53')
    expect(backend.ssh_command(record).take(4)).to eq(%w[podman --remote=false unshare --rootless-netns])
  end

  it 'keeps packet sockets private and relays bytes after the launching command exits' do
    runner = Empeira::Execution::Runner.new
    channel = Empeira::Network::Peer::Channel.new(context: app.context, runner: runner, record: record)
    channel.prepare
    server = UNIXServer.new(channel.socket)
    File.chmod(0o600, channel.socket)
    connection = nil
    accept = Thread.new { connection = server.accept }
    channel.start([RbConfig.ruby, '-e', 'STDOUT.sync=true; IO.copy_stream(STDIN,STDOUT)'])
    accept.join
    expect(channel).to be_healthy
    expect(File.stat(channel.socket).mode & 0o777).to eq(0o600)
    connection.write("\x00\xffpeer".b)
    expect(connection.read(6)).to eq("\x00\xffpeer".b)
    channel.stop
    expect(channel).not_to be_healthy
  ensure
    accept&.kill&.join
    connection&.close
    server&.close
    channel&.destroy
  end
end
