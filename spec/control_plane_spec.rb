# frozen_string_literal: true

require_relative 'support/service_runtime'
require_relative 'support/openvox_view'

RSpec.describe Empeira::ControlPlane::Controller do
  include OpenVoxViewFixture

  let(:runtime) { ServiceRuntime.new }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }

  def context(config = {})
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    Empeira::Application.new(project_path: @directory, locations: locations).context
  end

  def controller(config = {})
    current = context(config)
    plane = described_class.new(context: current, runtime: runtime, store: @store)
    (@contexts ||= {})[plane] = current
    plane
  end

  def mutate(object, operation)
    @store.with_lock do
      object.public_send(operation)
    end
  end

  def updater(plane)
    Empeira::Updates::Modules.new(context: @contexts.fetch(plane), runtime: runtime,
                                  runner: Empeira::Execution::Runner.new)
  end

  before do
    current = context
    @store = Empeira::Infrastructure::Store.new(context: current)
    definition = Empeira::Infrastructure::Definition.new(context: current)
    @store.with_lock do
      @store.write('peer_network' => { 'subnet' => '172.20.0.0/24' },
                   'schema_version' => 2, 'workspace' => current.workspace.id, 'runtime' => 'podman',
                   'resources' => { 'network' => { 'id' => 'network-id', 'name' => definition.network.backend_name,
                                                   'logical_identity' => definition.network.identity } },
                   'definition' => definition.metadata, 'fingerprint' => definition.fingerprint,
                   'component_fingerprints' => definition.component_fingerprints,
                   'created_at' => Time.now.utc.iso8601, 'reconciled_at' => Time.now.utc.iso8601)
    end
    allow(Empeira::ControlPlane::Health).to receive(:new).and_return(
      instance_double(Empeira::ControlPlane::Health, wait: nil, ready?: true)
    )
    allow(Empeira::Runtime::MountProbe).to receive(:new).and_return(instance_double(Empeira::Runtime::MountProbe,
                                                                                    verify: nil))
  end

  it 'rejects server mount conflicts and vanished sources before any runtime mutation' do
    source = File.join(@directory, 'artifact.txt')
    File.write(source, 'fixture')
    mount = { 'source' => source, 'target' => '/etc/puppetlabs/puppet/ssl' }
    conflicting = controller('server' => { 'mounts' => [mount] })
    expect { mutate(conflicting, :up) }.to raise_error(Empeira::ConfigurationError, /overlaps/)
    expect(runtime.calls).to be_empty
    valid = controller('server' => { 'mounts' => [mount.merge('target' => '/srv/artifact.txt')] })
    File.unlink(source)
    expect { mutate(valid, :up) }.to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].source/)
    expect(runtime.calls).to be_empty
  end

  it 'starts dependency-ordered services and reuses their IDs on repeated up' do
    plane = controller
    expect(mutate(plane, :up)).to be(true)
    ids = runtime.services.transform_values { |resource| resource['id'] }
    corefile = Empeira::ControlPlane::Files.new(context: context).path('Corefile')
    inode = File.stat(corefile).ino
    expect(runtime.calls.select { |entry| entry.first == :create }.map(&:last))
      .to eq(%w[gateway dns postgres server puppetdb-backend puppetdb])
    expect(mutate(controller, :up)).to be(false)
    expect(runtime.services.transform_values { |resource| resource['id'] }).to eq(ids)
    expect(File.stat(corefile).ino).to eq(inode)
    expect(runtime.calls.none? { |entry| entry.first == :reload }).to be(true)
    expect(plane.status).to include('Server' => 'running', 'Puppetdb' => 'running',
                                    'Puppetdb-backend' => 'running', 'Postgres' => 'running',
                                    'Dns' => 'running')
  end

  it 'preserves unchanged discovery files and shares lockdown only until policy application' do
    plane = controller
    mutate(plane, :up)
    files = Empeira::ControlPlane::Files.new(context: @contexts.fetch(plane))
    names = %w[Corefile hosts proxy-rules.conf proxy-clients]
    inodes = names.to_h { |name| [name, File.stat(files.path(name)).ino] }
    runtime.calls.clear
    expect(mutate(plane, :up)).to be(false)
    expect(names.to_h { |name| [name, File.stat(files.path(name)).ino] }).to eq(inodes)
    commands = runtime.calls.filter_map do |kind, args|
      args if kind == :exec && args.first == Empeira::Network::Gateway::EXECUTABLE
    end
    expect(commands.map { |args| args[1] }).to eq(%w[lockdown apply])
    runtime.calls.clear
    allow(plane).to receive(:prepare_server).and_raise(Empeira::Error, 'synthetic failure after apply')
    expect { mutate(plane, :up) }.to raise_error(Empeira::Error, /synthetic failure/)
    commands = runtime.calls.filter_map do |kind, args|
      args if kind == :exec && args.first == Empeira::Network::Gateway::EXECUTABLE
    end
    expect(commands.map { |args| args[1] }).to eq(%w[lockdown apply lockdown])
  end

  it 'reports a service that exits during startup before attempting to join its network namespace' do
    plane = controller('server' => { 'runtime' => { 'startup' => { 'eyaml_keys' => 'staged' } } })
    allow(runtime).to receive(:start_service).and_wrap_original do |method, resource|
      method.call(resource)
      resource['state'] = 'exited' if resource.equal?(runtime.services['server'])
    end

    expect { mutate(plane, :up) }
      .to raise_error(Empeira::Error, /Managed service server is exited after start; inspect podman logs [a-f0-9]+/)
    server_id = runtime.services.fetch('server').fetch('id')
    expect(runtime.calls.none? { |call| call[0] == :route && call[1] == server_id }).to be(true)
    expect(@store.load.dig('control_plane', 'services', 'server', 'id')).to eq(server_id)
  end

  it 'batches a warm reconcile and refreshes observations after success or failure' do
    plane = controller
    mutate(plane, :up)
    allow(runtime).to receive(:inspect_services).and_call_original
    expect(mutate(plane, :up)).to be(false)
    expect(runtime).to have_received(:inspect_services).once
    runtime.services.fetch('server').fetch('labels')['io.empeira.workspace'] = 'foreign'
    expect { mutate(plane, :up) }.to raise_error(Empeira::Providers::OwnershipError)
    runtime.services.fetch('server').fetch('labels')['io.empeira.workspace'] = context.workspace.id
    runtime.services.delete('server')
    expect(mutate(plane, :up)).to be(true)
    expect(runtime.services.fetch('server').fetch('state')).to eq('running')
  end

  it 'reports a service exit that races with route installation' do
    plane = controller('server' => { 'runtime' => { 'startup' => { 'eyaml_keys' => 'staged' } } })
    allow(runtime).to receive(:configure_workspace_route).and_wrap_original do |method, resource, **options|
      if resource.equal?(runtime.services['server'])
        resource['state'] = 'exited'
        raise Empeira::Providers::ExecutionError, 'podman workspace default routing failed (126)'
      end

      method.call(resource, **options)
    end

    expect { mutate(plane, :up) }.to raise_error(Empeira::Error, /Managed service server is exited after start/)
  end

  it 'refreshes staged Puppet Server EYAML keys on every up' do
    File.write(File.join(@directory, 'private.pem'), 'synthetic private material')
    File.write(File.join(@directory, 'public.pem'), 'synthetic certificate')
    plane = controller('server' => { 'runtime' => { 'startup' => { 'eyaml_keys' => 'staged' } } },
                       'eyaml' => { 'enabled' => true, 'private_key' => 'private.pem',
                                    'public_key' => 'public.pem' })
    refresh = [:exec, ['/bin/sh', '/empeira-server/start.sh', 'refresh-eyaml']]

    mutate(plane, :up)
    mutate(controller('server' => { 'runtime' => { 'startup' => { 'eyaml_keys' => 'staged' } } },
                      'eyaml' => { 'enabled' => true, 'private_key' => 'private.pem',
                                   'public_key' => 'public.pem' }), :up)
    expect(runtime.calls.count(refresh)).to eq(2)
  end

  it 're-resolves and reconciles direct TCP egress without changing the proxy path' do
    state = @store.load
    state['peer_network'] = { 'subnet' => '10.203.20.0/24' }
    @store.write(state)
    first = Empeira::Network::DirectEgress::Resolved.new(
      [{ 'host' => 'api.example.com',
         'addresses' => ['192.0.2.10'], 'ports' => [443] }]
    )
    second = Empeira::Network::DirectEgress::Resolved.new(
      [{ 'host' => 'api.example.com',
         'addresses' => ['192.0.2.11'], 'ports' => [443] }]
    )
    resolver = instance_double(Empeira::Network::DirectEgress::Resolver)
    allow(resolver).to receive(:resolve).and_return(first, second)
    allow(Empeira::Network::DirectEgress::Resolver).to receive(:new).and_return(resolver)
    config = { 'network' => { 'egress' => [{ 'host' => 'api.example.com', 'ports' => [443] }] },
               'puppetdb' => { 'enabled' => false } }
    plane = controller(config)

    expect(mutate(plane, :up)).to be(true)
    gateway = runtime.services.fetch('gateway')
    expect(gateway.fetch('networks').keys).to contain_exactly(
      Empeira::ControlPlane::Plan.new(context: context(config)).network,
      Empeira::Network::Egress.new(workspace: context(config).workspace,
                                   policy: Empeira::Network::Policy.new).backend_name
    )
    lockdown = [:exec, ['/usr/local/libexec/empeira-gateway', 'lockdown']]
    apply = [:exec, ['/usr/local/libexec/empeira-gateway', 'apply',
                     '/empeira-gateway/gateway.json']]
    expect(runtime.calls).to include(lockdown, apply)
    expect(runtime.calls.index(lockdown)).to be < runtime.calls.index(apply)
    expect(File.read(Empeira::ControlPlane::Files.new(context: context(config)).path('hosts')))
      .not_to include('api.example.com')
    fresh_plan = Empeira::ControlPlane::Plan.new(context: context(config))
    Empeira::ControlPlane::Discovery.new(plan: fresh_plan, runtime: runtime, state: @store.load).refresh
    expect(File.read(fresh_plan.files.path('hosts'))).not_to include('api.example.com')
    first_id = gateway.fetch('id')

    expect(mutate(plane, :up)).to be(true)
    expect(runtime.services.fetch('gateway').fetch('id')).to eq(first_id)
    expect(runtime.calls.count { |call| call == [:create, 'gateway'] }).to eq(1)
    expect(runtime.services).not_to have_key('proxy')

    expect(mutate(plane, :down)).to be(true)
    executions = runtime.calls.count { |call| call == apply }
    expect(mutate(plane, :up)).to be(true)
    expect(runtime.calls.count { |call| call == apply })
      .to eq(executions + 1)
  end

  it 'replaces the server for changed direct-egress bypass destinations but retains it for port changes' do
    config = { 'puppetdb' => { 'enabled' => false }, 'network' => { 'egress' => [] } }
    mutate(controller(config), :up)
    ids = runtime.services.transform_values { |resource| resource.fetch('id') }
    config['network']['egress'] = [{ 'ip' => '192.0.2.20', 'ports' => [443] }]
    mutate(controller(config), :up)
    granted_server = runtime.services.fetch('server').fetch('id')
    expect(granted_server).not_to eq(ids.fetch('server'))
    config['network']['egress'].first['ports'] = [8443]
    expect(mutate(controller(config), :up)).to be(true)
    expect(runtime.services.fetch('server').fetch('id')).to eq(granted_server)
    config['network']['egress'] = []
    mutate(controller(config), :up)
    expect(runtime.services.fetch('server').fetch('id')).not_to eq(granted_server)
    %w[gateway dns].each { |key| expect(runtime.services.fetch(key).fetch('id')).to eq(ids.fetch(key)) }
  end

  it 'removes direct grants while retaining the shared gateway and checkpoint' do
    state = @store.load
    state['peer_network'] = { 'subnet' => '10.203.20.0/24' }
    @store.write(state)
    resolved = Empeira::Network::DirectEgress::Resolved.new(
      [{ 'host' => 'api.example.com',
         'addresses' => ['192.0.2.10'], 'ports' => [443] }]
    )
    empty = Empeira::Network::DirectEgress::Resolved.new([])
    allow_any_instance_of(Empeira::Network::DirectEgress::Resolver).to receive(:resolve) do |_resolver, entries, **|
      entries.empty? ? empty : resolved
    end
    config = { 'network' => { 'egress' => [{ 'host' => 'api.example.com', 'ports' => [443] }] },
               'puppetdb' => { 'enabled' => false } }
    mutate(controller(config), :up)

    expect(mutate(controller('puppetdb' => { 'enabled' => false }), :up)).to be(true)
    expect(runtime.services).to have_key('gateway')
    expect(@store.load.fetch('control_plane')).to have_key('gateway_policy')
    files = Empeira::ControlPlane::Files.new(context: context('puppetdb' => { 'enabled' => false }))
    expect(File.read(files.path('hosts'))).not_to include('api.example.com')
    expect(JSON.parse(File.read(files.path('gateway.json'))).fetch('entries')).to be_empty
  end

  it 'rejects superseded alpha networking before starting a second egress model' do
    mutate(controller, :up)
    state = @store.load
    state['control_plane']['services'].delete('gateway')
    @store.write(state)
    calls = runtime.calls.size
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /network architecture changed/)
    expect(runtime.calls.size).to eq(calls)
  end

  it 'locks down existing grants before a failed DNS refresh' do
    mutate(controller, :up)
    allow_any_instance_of(Empeira::Network::DirectEgress::Resolver).to receive(:resolve)
      .and_raise(Empeira::Error, 'DNS resolution failed')
    calls = runtime.calls.size
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /DNS resolution/)
    expect(runtime.calls.drop(calls)).to include([:exec, [Empeira::Network::Gateway::EXECUTABLE, 'lockdown']])
    expect(runtime.calls.drop(calls).select { |entry| entry.first == :exec }.flatten).not_to include('apply')
  end

  it 'stops the gateway if firewall application fails and reports drift in status' do
    plane = controller
    mutate(plane, :up)
    allow(runtime).to receive(:service_exec).and_wrap_original do |original, resource, arguments, **options|
      if arguments.include?('apply') || arguments.include?('check')
        Empeira::Execution::Result.new(stdout: '', stderr: 'fixture firewall failure', exit_status: 1, timed_out: false)
      else
        original.call(resource, arguments, **options)
      end
    end
    expect(plane.status).to include('Workspace network' => 'unhealthy')
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /Gateway/)
    expect(runtime.services.fetch('gateway').fetch('state')).to eq('stopped')
  end

  it 'keeps bootstrap source exclusion and the status plan consistent' do
    plane = controller
    mutate(plane, :up)
    current = @contexts.fetch(plane)
    gateway = Empeira::Network::Gateway.new(context: current, runtime: runtime, state: @store.load)
    record = { 'definition' => { 'ip' => '172.20.0.96' } }
    gateway.phase(record, bootstrap: true)
    path = Empeira::ControlPlane::Files.new(context: current).path('gateway.json')
    expect(JSON.parse(File.read(path)).fetch('blocked')).to eq(['172.20.0.96'])
    gateway.phase(record, bootstrap: false)
    expect(JSON.parse(File.read(path)).fetch('blocked')).to be_empty
  end

  def redirect_configuration(ip: '192.0.2.8', source_port: 8080, service: 'api-compat', target_port: 8081)
    { 'puppetdb' => { 'enabled' => false },
      'containers' => { 'additional' => [{ 'name' => 'api-compat',
                                           'image' => { 'repository' => 'fixture/api', 'tag' => 'test' } }] },
      'network' => { 'redirects' => [{ 'from' => { 'ip' => ip, 'port' => source_port },
                                       'to' => { 'service' => service, 'port' => target_port } }] } }
  end

  def gateway_configuration(config)
    files = Empeira::ControlPlane::Files.new(context: context(config))
    JSON.parse(File.read(files.path('gateway.json')))
  end

  it 'resolves redirects after service startup, reuses identities and remains idempotent' do
    config = redirect_configuration
    expect(mutate(controller(config), :up)).to be(true)
    resource = runtime.services.fetch('api-compat')
    network = Empeira::ControlPlane::Plan.new(context: context(config)).network
    expect(gateway_configuration(config).fetch('redirects').first.fetch('to'))
      .to eq('ip' => resource.dig('networks', network, 'IPAddress'), 'port' => 8081)
    ids = runtime.services.transform_values { |service| service.fetch('id') }
    fingerprint = @store.load.dig('control_plane', 'gateway_policy')
    expect(mutate(controller(config), :up)).to be(false)
    expect(runtime.services.transform_values { |service| service.fetch('id') }).to eq(ids)
    expect(@store.load.dig('control_plane', 'gateway_policy')).to eq(fingerprint)
    expect(@store.load.fetch('control_plane')).not_to have_key('redirects')
    expect(@store.load.to_s).not_to include('192.0.2.8')
  end

  it 'reconciles source pairs, target services and ports, and removal without replacing other services' do
    first = redirect_configuration
    mutate(controller(first), :up)
    ids = runtime.services.transform_values { |service| service.fetch('id') }
    configurations = [redirect_configuration(ip: '192.0.2.9'), redirect_configuration(source_port: 8082),
                      redirect_configuration(service: 'server', target_port: 8140),
                      redirect_configuration(target_port: 8083)]
    configurations.each do |config|
      expect(mutate(controller(config), :up)).to be(true)
      expect(gateway_configuration(config).fetch('redirects').first.fetch('from'))
        .to eq(config.dig('network', 'redirects').first.fetch('from'))
      expect(runtime.services.transform_values { |service| service.fetch('id') }).to eq(ids)
    end
    removed = first.merge('network' => { 'redirects' => [] })
    expect(mutate(controller(removed), :up)).to be(true)
    expect(gateway_configuration(removed).fetch('redirects')).to eq([])
  end

  it 'blocks stale targets before recreation and refreshes their observed addresses afterwards' do
    config = redirect_configuration
    mutate(controller(config), :up)
    config['containers']['additional'][0]['environment'] = { 'REVISION' => 'next' }
    applied = []
    allow(runtime).to receive(:service_exec).and_wrap_original do |method, resource, arguments, **options|
      applied << gateway_configuration(config).fetch('redirects') if arguments.include?('apply')
      method.call(resource, arguments, **options)
    end
    mutate(controller(config), :up)
    expect(applied.first.first.fetch('to')).to be_nil
    expect(applied.last.first.fetch('to')).to include('port' => 8081)
    expect(runtime.calls).to include([:remove, 'api-compat'])
  end

  it 'rejects invalid service names and reserved source addresses before images or creation' do
    [redirect_configuration(service: 'absent'), redirect_configuration(ip: '172.20.0.3')].each do |config|
      expect { mutate(controller(config), :up) }.to raise_error(Empeira::ConfigurationError, /network.redirects/)
      expect(runtime.calls).to be_empty
    end
  end

  it 'fails explicitly and stops an old custom gateway instead of silently ignoring redirects' do
    allow(runtime).to receive(:service_exec).and_wrap_original do |method, resource, arguments, **options|
      result = method.call(resource, arguments, **options)
      arguments.include?('redirects-capability') ? result.with(stdout: '') : result
    end
    expect { mutate(controller(redirect_configuration), :up) }
      .to raise_error(Empeira::Error, /Gateway does not support transparent/)
    expect(runtime.services.fetch('gateway').fetch('state')).to eq('stopped')
  end

  it 'disables server environment caching and removes obsolete content checkpoints' do
    mutate(controller, :up)
    state = @store.load
    state['control_plane']['environment_cache'] = { 'fingerprint' => 'obsolete' }
    @store.with_lock { @store.write(state) }
    expect(mutate(controller, :up)).to be(false)
    expect(@store.load.fetch('control_plane')).not_to have_key('environment_cache')
    definition = Empeira::ControlPlane::Plan.new(context: context).definitions.fetch('server')
    expect(definition.options.fetch('environment')).to include('OPENVOXSERVER_ENVIRONMENT_TIMEOUT' => '0')
    expect(runtime.calls.none? { |call| call.first == :exec && call.last.include?('DELETE') }).to be(true)
  end

  it 'activates the additional resolver only after its service starts and keeps repeated up idle' do
    config = helper_services('resolver').merge(
      'dns' => { 'additional_resolver' => 'resolver.empeira.internal',
                 'upstream' => { 'mode' => 'explicit', 'servers' => ['10.20.30.1'] } },
      'puppetdb' => { 'enabled' => false }
    )
    corefile = Empeira::ControlPlane::Files.new(context: context(config)).path('Corefile')
    snapshots = {}
    allow(runtime).to receive(:start_service).and_wrap_original do |start, resource|
      start.call(resource)
      key = resource.fetch('name').split('-').last
      snapshots[key] = File.read(corefile) if %w[dns resolver].include?(key)
    end
    allow(runtime).to receive(:reload_service).and_wrap_original do |reload, resource, **options|
      expect(runtime.services.fetch('resolver').fetch('state')).to eq('running')
      expect(File.read(corefile)).to include('forward . resolver.empeira.internal')
      reload.call(resource, **options)
    end

    expect(mutate(controller(config), :up)).to be(true)
    expect(snapshots.fetch('dns')).to include('forward . 10.20.30.1')
    expect(snapshots.fetch('dns')).not_to include('resolver.empeira.internal')
    expect(snapshots.fetch('resolver')).not_to include('resolver.empeira.internal')
    expect(File.read(corefile)).to include('forward . resolver.empeira.internal', 'next_on_nodata', 'reload')

    ids = runtime.services.transform_values { |resource| resource.fetch('id') }
    expect(runtime.calls).to include([:reload, ids.fetch('dns'), 'USR1'])
    inode = File.stat(corefile).ino
    call_count = runtime.calls.size
    expect(mutate(controller(config), :up)).to be(false)
    expect(runtime.services.transform_values { |resource| resource.fetch('id') }).to eq(ids)
    expect(File.stat(corefile).ino).to eq(inode)
    expect(runtime.calls.drop(call_count)).not_to include([:create, 'dns'], [:reload, ids.fetch('dns'), 'USR1'])
  end

  it 'bootstraps DNS again after down without requiring an additional service entry' do
    config = { 'dns' => { 'additional_resolver' => '10.20.30.53',
                          'upstream' => { 'mode' => 'explicit', 'servers' => ['10.20.30.1'] } },
               'puppetdb' => { 'enabled' => false } }
    corefile = Empeira::ControlPlane::Files.new(context: context(config)).path('Corefile')
    mutate(controller(config), :up)
    expect(File.read(corefile)).to include('forward . 10.20.30.53')
    mutate(controller(config), :down)

    at_start = nil
    allow(runtime).to receive(:start_service).and_wrap_original do |start, resource|
      at_start = File.read(corefile) if resource.fetch('name').end_with?('-dns')
      start.call(resource)
    end
    mutate(controller(config), :up)
    expect(at_start).not_to include('resolver.example.test')
    expect(File.read(corefile)).to include('forward . 10.20.30.53')
  end

  it 'reconciles a refreshed image only during up and rechecks artifacts when the controller is reused' do
    reference = 'registry.example/stack/server:1'
    plane = controller('images' => { 'server' => { 'reference' => reference } })
    mutate(plane, :up)
    previous = runtime.services.transform_values { |resource| resource.fetch('id') }
    allow(runtime).to receive(:image_id).with(anything).and_return(nil)
    allow(runtime).to receive(:image_id).with(reference).and_return('new-image')
    expect(runtime.services.transform_values { |resource| resource.fetch('id') }).to eq(previous)
    mutate(plane, :up)
    expect(runtime.services.fetch('server').fetch('id')).not_to eq(previous.fetch('server'))
    expect(runtime.services.except('server').transform_values { |resource| resource.fetch('id') })
      .to eq(previous.except('server'))
  end

  it 'rejects failed image acquisition before changing services or storage' do
    allow(runtime).to receive(:ensure_image).and_raise(Empeira::Error, 'image acquisition failed')
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /image acquisition failed/)
    expect(runtime.services).to be_empty
    expect(runtime.volumes).to be_empty
  end

  it 'keeps an existing gateway closed and preserves services when a pull is rate limited' do
    plane = controller
    mutate(plane, :up)
    services = Marshal.load(Marshal.dump(runtime.services))
    inventory = @store.load
    calls = runtime.calls.size
    allow(runtime).to receive(:ensure_image)
      .and_raise(Empeira::Providers::ExecutionError, 'toomanyrequests: unauthenticated pull rate limit')

    expect { mutate(plane, :up) }.to raise_error(Empeira::Providers::ExecutionError, /pull rate limit/)
    expect(runtime.calls.drop(calls)).to eq([[:exec, [Empeira::Network::Gateway::EXECUTABLE, 'lockdown']]])
    expect(runtime.services).to eq(services)
    expect(@store.load).to eq(inventory)
  end

  it 'retains all persistent volumes and credentials across down/up' do
    mutate(controller, :up)
    volumes = Marshal.load(Marshal.dump(runtime.volumes))
    credentials = File.read(Empeira::ControlPlane::Files.new(context: context).secret_path)
    expect(mutate(controller, :down)).to be(true)
    expect(runtime.services).to be_empty
    expect(runtime.volumes).to eq(volumes)
    expect(mutate(controller, :down)).to be(false)
    mutate(controller, :up)
    expect(runtime.volumes).to eq(volumes)
    expect(File.read(Empeira::ControlPlane::Files.new(context: context).secret_path)).to eq(credentials)
  end

  it 'fails closed when retained storage or credentials disappear' do
    mutate(controller, :up)
    runtime.volumes.delete('openvox-ca')
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /missing/)
    File.unlink(Empeira::ControlPlane::Files.new(context: context).secret_path)
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /credentials/)
  end

  it 'does not regenerate credentials when inventory is lost but an owned database volume remains' do
    mutate(controller, :up)
    inventory = @store.load
    inventory.delete('control_plane')
    @store.with_lock { @store.write(inventory) }
    credentials = Empeira::ControlPlane::Files.new(context: context).secret_path
    File.unlink(credentials)
    expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /credentials/)
    expect(File).not_to exist(credentials)
    expect(runtime.volumes).to have_key('openvox-postgres-data')
  end

  it 'rejects replacement of a recorded service or volume even with matching ownership labels' do
    mutate(controller, :up)
    runtime.services['server']['id'] = 'replacement'
    expect { mutate(controller, :down) }.to raise_error(Empeira::Providers::OwnershipError)
    runtime.volumes['openvox-ca']['id'] = 'replacement'
    expect { mutate(controller, :up) }.to raise_error(Empeira::Providers::OwnershipError)
  end

  it 'recovers a committed creation after interruption without duplicate services' do
    runtime.failure = 'server'
    expect { mutate(controller, :up) }.to raise_error(Empeira::Providers::ExecutionError)
    saved = runtime.services['server']['id']
    expect(@store.load.dig('control_plane', 'services', 'server', 'id')).to be_nil
    runtime.failure = nil
    mutate(controller, :up)
    expect(runtime.services['server']['id']).to eq(saved)
    expect(runtime.calls.count { |entry| entry == [:create, 'server'] }).to eq(1)
  end

  it 'waits for the proxy listener before sending its first policy reload' do
    ready = false
    health = instance_double(Empeira::ControlPlane::Health, ready?: true)
    allow(health).to receive(:wait) { |key, _resources| ready = true if key == 'proxy' }
    allow(Empeira::ControlPlane::Health).to receive(:new).and_return(health)
    expect(runtime).to receive(:reload_service).once do |_resource|
      expect(ready).to be(true)
    end
    mutate(controller('proxy' => { 'enabled' => true }), :up)
  end

  it 'reloads proxy policy without replacing services and keeps unchanged policy idle' do
    config = { 'proxy' => { 'enabled' => true, 'global' => ['example.org'] } }
    mutate(controller(config), :up)
    state = @store.load
    state['nodes'] = rewrite_node_records
    @store.with_lock { @store.write(state) }
    mutate(controller(config), :up)
    ids = runtime.services.transform_values { |resource| resource['id'] }
    runtime.calls.clear
    config['proxy']['rules'] = [{ 'hosts' => ['*-node'], 'allow' => ['example.net'] }]
    expect(mutate(controller(config), :up)).to be(true)
    expect(runtime.services.transform_values { |resource| resource['id'] }).to eq(ids)
    expect(runtime.calls).to include([:reload, ids.fetch('proxy'), 'HUP'])
    runtime.calls.clear
    expect(mutate(controller(config), :up)).to be(false)
    expect(runtime.calls.none? { |call| call.first == :reload }).to be(true)
    config['proxy']['global'] = ['packages.example.org']
    expect(mutate(controller(config), :up)).to be(true)
    expect(runtime.services.transform_values { |resource| resource['id'] }).to eq(ids)
    expect(runtime.calls).to include([:reload, ids.fetch('proxy'), 'HUP'])
    expect(runtime.networks.size).to eq(1)
    expect(runtime.services.except('gateway').values.map { |item| item['networks'].size }.uniq).to eq([1])
  end

  it 'retries a failed proxy reload even when the desired files are already current' do
    config = { 'proxy' => { 'enabled' => true, 'global' => ['example.org'] } }
    mutate(controller(config), :up)
    checkpoint = @store.load.dig('control_plane', 'proxy_reload')
    config['proxy']['global'] = ['example.net']
    allow(runtime).to receive(:reload_service).and_raise(Empeira::Providers::ExecutionError, 'reload failed')
    expect { mutate(controller(config), :up) }.to raise_error(Empeira::Providers::ExecutionError, /reload failed/)
    expect(@store.load.dig('control_plane', 'proxy_reload')).to eq(checkpoint)
    allow(runtime).to receive(:reload_service).and_call_original
    runtime.calls.clear
    mutate(controller(config), :up)
    expect(runtime.calls).to include([:reload, checkpoint.fetch('id'), 'HUP'])
    expect(@store.load.dig('control_plane', 'proxy_reload')).not_to eq(checkpoint)
    runtime.calls.clear
    expect(mutate(controller(config), :up)).to be(false)
    expect(runtime.calls.none? { |call| call.first == :reload }).to be(true)
    state = @store.load
    state['control_plane']['proxy_reload'] = checkpoint.merge('fingerprint' => 'malformed')
    expect { @store.with_lock { @store.write(state) } }.to raise_error(Empeira::Infrastructure::StateError)
  end

  it 'replaces a proxy with the previous IP restriction on up without changing user policy or other services' do
    config = { 'proxy' => { 'enabled' => true, 'global' => ['example.org'] } }
    mutate(controller(config), :up)
    current = Empeira::ControlPlane::Plan.new(context: context(config))
    definition = current.definitions.fetch('proxy')
    previous_policy = current.files.configuration.fetch('squid.conf')
                             .sub('http_access deny !Safe_ports',
                                  "acl forbidden dst #{Empeira::Network::ProxyPolicy::FORBIDDEN}\n" \
                                  'http_access deny !Safe_ports')
                             .sub('include /empeira-proxy/proxy-rules.conf',
                                  "http_access deny forbidden\ninclude /empeira-proxy/proxy-rules.conf")
    previous = Empeira::Services::Definition.new(key: 'proxy', workspace: current.context.workspace,
                                                 **definition.options.merge('configuration' => previous_policy))
    runtime.services.fetch('proxy').fetch('labels')['io.empeira.definition'] = previous.fingerprint
    File.write(current.files.path('squid.conf'), previous_policy.gsub('@EMPEIRA_DNS@', '172.20.0.2'))
    ids = runtime.services.transform_values { |resource| resource['id'] }

    expect(mutate(controller(config), :up)).to be(true)
    actual = runtime.services.transform_values { |resource| resource['id'] }
    expect(actual.except('proxy')).to eq(ids.except('proxy'))
    expect(actual.fetch('proxy')).not_to eq(ids.fetch('proxy'))
    expect(File.read(current.files.path('squid.conf'))).not_to include('forbidden', '@EMPEIRA_DNS@')
    expect(mutate(controller(config), :up)).to be(false)
    expect(runtime.services.transform_values { |resource| resource['id'] }).to eq(actual)
  end

  it 'removes proxy but retains the common DNS gateway when disabling proxy access' do
    mutate(controller('proxy' => { 'enabled' => true }), :up)
    mutate(controller, :up)
    expect(runtime.services).not_to have_key('proxy')
    expect(runtime.networks.size).to eq(1)
  end

  it 'refuses an unexpected externally attached network before declaring readiness' do
    mutate(controller, :up)
    runtime.services['server']['networks']['unrestricted'] = {}
    expect { mutate(controller, :up) }.to raise_error(Empeira::Providers::OwnershipError, /network/)
  end

  it 'supports disabling PuppetDB without deleting its database volumes' do
    mutate(controller, :up)
    mutate(controller('puppetdb' => { 'enabled' => false }), :up)
    expect(runtime.services.keys).to match_array(%w[gateway dns server])
    expect(runtime.volumes).to have_key('openvox-postgres-data')
  end

  it 'removes retained volumes only through explicit destroy' do
    mutate(controller, :up)
    mutate(controller, :destroy)
    expect(runtime.services).to be_empty
    expect(runtime.volumes).to be_empty
    expect(File).not_to exist(Empeira::ControlPlane::Files.new(context: context).secret_path)
  end
  def helper_services(*names)
    { 'containers' => { 'additional' => names.map do |name|
      { 'name' => name, 'image' => { 'repository' => 'example/helper', 'tag' => '1' } }
    end } }
  end

  it 'adds, changes and removes DNS rewrites without replacing services or restarting either node provider' do
    config = helper_services('api-layer', 'other-api')
    mutate(controller(config), :up)
    state = @store.load
    state['nodes'] = rewrite_node_records
    @store.with_lock { @store.write(state) }
    ids = runtime.services.transform_values { |resource| resource.fetch('id') }
    files = Empeira::ControlPlane::Files.new(context: context(config))
    config['dns'] = { 'rewrites' => [{ 'from' => 'ipam.example.net', 'to' => 'api-layer.empeira.internal' }] }

    [config, config.merge('dns' => { 'rewrites' => [{ 'from' => 'ipam.example.net',
                                                      'to' => 'other-api.empeira.internal' }] }),
     config.merge('dns' => { 'rewrites' => [] })].each do |desired|
      runtime.calls.clear
      expect(mutate(controller(desired), :up)).to be(true)
      expect(runtime.services.transform_values { |resource| resource.fetch('id') }).to eq(ids)
      expect(runtime.calls).to include([:reload, ids.fetch('dns'), 'USR1'])
      expect(runtime.calls.select { |call| %i[create remove start stop].include?(call.first) }).to be_empty
      expect(@store.load.fetch('nodes')).to eq(state.fetch('nodes'))
      before = File.stat(files.path('Corefile')).ino
      runtime.calls.clear
      expect(mutate(controller(desired), :up)).to be(false)
      expect(File.stat(files.path('Corefile')).ino).to eq(before)
      expect(runtime.calls).not_to include([:reload, ids.fetch('dns'), 'USR1'])
    end
    expect(File.read(files.path('Corefile'))).not_to include('ipam.example.net')
    replacement = config.merge('dns' => { 'rewrites' => [] },
                               'images' => { 'dns' => { 'repository' => 'example/dns', 'tag' => 'changed' } })
    expect { mutate(controller(replacement), :up) }
      .to raise_error(Empeira::Error, /DNS replacement would invalidate existing node resolver bindings/)
    expect(runtime.services.transform_values { |resource| resource.fetch('id') }).to eq(ids)
  end

  # rubocop:disable-next Metrics/MethodLength -- Complete synthetic records exercise the real inventory validator.
  def rewrite_node_records
    common = { 'os' => 'ubuntu', 'version' => '24.04', 'architecture' => 'amd64',
               'created_at' => Time.now.utc.iso8601, 'provisioned' => true }
    container = common.merge('provider' => 'container', 'runtime' => 'podman', 'hostname' => 'container-node',
                             'image' => 'example/node:1', 'id' => 'node-id',
                             'definition' => { 'hostname' => 'container-node', 'image' => 'example/node:1',
                                               'ip' => '172.20.0.96' })
    vm = common.merge('provider' => 'vm', 'management_layout' => Empeira::VM::Management::VERSION,
                      'hostname' => 'vm-node', 'engine' => 'qemu', 'accelerator' => 'kvm',
                      'memory' => 1024, 'cpus' => 1, 'ssh_port' => 22_000, 'state' => 'running',
                      'overlay' => 'vms/vm-node/disk.qcow2', 'network' => "#{context.workspace.id}:environment",
                      'mac_address' => '52:54:00:00:00:01',
                      'peer' => { 'ip' => '172.20.0.32', 'token' => 'a' * 32, 'backend' => 'DockerAdapter',
                                  'dns' => '172.20.0.3' },
                      'base_image' => { 'distribution' => 'ubuntu', 'version' => '24.04', 'architecture' => 'amd64',
                                        'source' => 'https://images.example.net/base', 'revision' => 'synthetic',
                                        'checksum' => 'a' * 64 })
    { 'container-node' => container, 'vm-node' => vm }
  end

  it 'refreshes rewrite target addresses through ordinary discovery without reloading CoreDNS' do
    config = helper_services('api-layer').merge(
      'dns' => { 'rewrites' => [{ 'from' => 'ipam.example.net', 'to' => 'api-layer.empeira.internal' }] }
    )
    mutate(controller(config), :up)
    plan = Empeira::ControlPlane::Plan.new(context: context(config))
    runtime.services.fetch('api-layer').dig('networks', plan.network)['IPAddress'] = '172.20.0.222'
    runtime.calls.clear
    mutate(controller(config), :up)
    expect(File.read(plan.files.path('hosts'))).to include('172.20.0.222 api-layer api-layer.empeira.internal')
    expect(runtime.calls.none? { |call| call.first == :reload }).to be(true)
  end

  it 'rejects missing rewrite services before acquiring images or mutating infrastructure' do
    plane = controller('dns' => { 'rewrites' => [{ 'from' => 'ipam.example.net',
                                                   'to' => 'missing.empeira.internal' }] })
    expect { mutate(plane, :up) }.to raise_error(Empeira::ConfigurationError, /target service.*missing or disabled/)
    expect(runtime.calls).to be_empty
  end

  it 'reconciles additional services, records DNS, replaces changes and removes deleted services' do
    config = helper_services('first', 'second')
    mutate(controller(config), :up)
    ids = runtime.services.transform_values { |resource| resource['id'] }
    hosts = File.read(Empeira::ControlPlane::Files.new(context: context(config)).path('hosts'))
    expect(hosts).to include('first.empeira.internal', 'second.empeira.internal')
    expect(controller(config).status).to include('First' => 'running', 'Second' => 'running')
    mutate(controller(config), :up)
    expect(runtime.services.transform_values { |resource| resource['id'] }).to eq(ids)
    config['containers']['additional'].first['environment'] = { 'KEY' => 'changed' }
    config['containers']['additional'].pop
    mutate(controller(config), :up)
    expect(runtime.services['first']['id']).not_to eq(ids['first'])
    expect(runtime.services).not_to have_key('second')
    expect(runtime.services['server']['id']).to eq(ids['server'])
    expect(File.read(Empeira::ControlPlane::Files.new(context: context(config)).path('hosts')))
      .not_to include('second.empeira.internal')
    mutate(controller(config), :down)
    expect(runtime.services).to be_empty
  end

  it 'manages the OpenVox View example through the ordinary additional-service lifecycle' do
    config = { 'containers' => { 'additional' => [openvox_view] } }
    plane = controller(config)
    mutate(plane, :up)
    expect(plane.status).to include('Openvoxview' => 'running')
    expect(runtime.services.fetch('openvoxview').fetch('ports')).to be_empty
    hosts = Empeira::ControlPlane::Files.new(context: context(config)).path('hosts')
    expect(File.read(hosts)).to include('openvoxview.empeira.internal')
    mutate(plane, :down)
    expect(runtime.services).not_to have_key('openvoxview')
    mutate(plane, :up)
    expect(plane.status).to include('Openvoxview' => 'running')
    mutate(plane, :destroy)
    expect(runtime.services).not_to have_key('openvoxview')
  end

  it 'starts the browser on demand, reuses it, replaces its image and removes both containers on down' do
    plane = controller
    mutate(plane, :up)
    expect(mutate(plane, :browser)).to eq('https://127.0.0.1:32124/')
    browser = runtime.services.fetch('browser')
    expect(browser.fetch('networks').size).to eq(1)
    expect(browser.fetch('ports')).to be_empty
    expect(runtime.services.fetch('browser-ui').fetch('networks').size).to eq(2)
    mutate(controller, :up)
    expect(runtime.services.fetch('browser')['id']).to eq(browser['id'])
    config = { 'browser' => { 'image' => { 'repository' => 'registry.example/browser', 'tag' => '2' } } }
    mutate(controller(config), :browser)
    expect(runtime.services.fetch('browser')['id']).not_to eq(browser['id'])
    expect(runtime.calls).to include([:image, 'registry.example/browser:2'])
    mutate(controller(config), :down)
    expect(runtime.services).to be_empty
  end

  it 'recreates only the browser when its start URL changes, without waiting for that application' do
    plane = controller
    mutate(plane, :up)
    mutate(plane, :browser)
    before = runtime.services.transform_values { |resource| resource.fetch('id') }
    config = { 'browser' => { 'start_url' => 'http://unavailable.empeira.internal:5000' } }
    mutate(controller(config), :browser)
    after = runtime.services.transform_values { |resource| resource.fetch('id') }
    expect(after.fetch('browser')).not_to eq(before.fetch('browser'))
    expect(after.except('browser')).to eq(before.except('browser'))
    mutate(controller(config), :browser)
    expect(runtime.services.fetch('browser').fetch('id')).to eq(after.fetch('browser'))
  end

  it 'does not start stopped infrastructure or change its inventory on repeated browser requests' do
    plane = controller
    mutate(plane, :up)
    %w[server postgres puppetdb-backend puppetdb].each { |key| runtime.services.fetch(key)['state'] = 'stopped' }
    state_before = JSON.parse(JSON.generate(@store.load))
    runtime.calls.clear

    expect(mutate(plane, :browser)).to eq('https://127.0.0.1:32124/')
    infrastructure_calls = runtime.calls.select { |call| %i[create start remove reload].include?(call.first) }
    expect(infrastructure_calls.select { |call| call.last.to_s.match?(/server|postgres|puppetdb/) }).to be_empty
    infrastructure = runtime.services.values_at('server', 'postgres', 'puppetdb-backend', 'puppetdb')
    expect(infrastructure.map { |item| item['state'] })
      .to all(eq('stopped'))

    state_after = JSON.parse(JSON.generate(@store.load))
    state_after.fetch('control_plane').fetch('services').delete('browser')
    state_after.fetch('control_plane').fetch('services').delete('browser-ui')
    expect(state_after).to eq(state_before)

    browser_ids = runtime.services.slice('browser', 'browser-ui').transform_values { |item| item.fetch('id') }
    repeated_state = JSON.parse(JSON.generate(@store.load))
    runtime.calls.clear
    expect(mutate(controller, :browser)).to eq('https://127.0.0.1:32124/')
    expect(runtime.calls.none? { |call| %i[create start remove reload].include?(call.first) }).to be(true)
    expect(runtime.services.slice('browser', 'browser-ui').transform_values { |item| item.fetch('id') })
      .to eq(browser_ids)
    expect(@store.load).to eq(repeated_state)
  end

  %w[missing stopped].each do |condition|
    it "fails clearly instead of reconciling a #{condition} required DNS service" do
      plane = controller
      mutate(plane, :up)
      condition == 'missing' ? runtime.services.delete('dns') : runtime.services.fetch('dns')['state'] = 'stopped'
      state_before = @store.load
      runtime.calls.clear

      message = "Required service dns is not running. Start the workspace with 'empeira up' first."
      expect { mutate(plane, :browser) }.to raise_error(Empeira::Error, message)
      expect(runtime.calls.none? { |call| %i[create start remove reload].include?(call.first) }).to be(true)
      expect(runtime.services['dns']&.fetch('state')).to eq(condition == 'missing' ? nil : 'stopped')
      expect(@store.load).to eq(state_before)
    end
  end

  it 'rejects unexpected browser egress, public UI bindings and foreign service ownership' do
    plane = controller
    mutate(plane, :up)
    mutate(plane, :browser)
    runtime.services['browser']['networks']['foreign'] = {}
    expect { plane.status }.to raise_error(Empeira::Providers::OwnershipError)
    runtime.services['browser']['networks'].delete('foreign')
    runtime.services['browser-ui']['ports']['3001/tcp'][0]['HostIp'] = '0.0.0.0'
    expect { plane.status }.to raise_error(Empeira::Providers::OwnershipError)
    runtime.services['browser-ui']['ports']['3001/tcp'][0]['HostIp'] = '127.0.0.1'
    runtime.services['browser']['labels']['io.empeira.workspace'] = 'foreign'
    expect { mutate(plane, :down) }.to raise_error(Empeira::Providers::OwnershipError)
  end
  context 'Puppetfile modules' do
    before do
      File.write(File.join(@directory, 'Puppetfile'),
                 "mod 'profile', git: 'https://git.example.org/profile', tag: 'v1'\n")
      @installed_requests = []
      @installer = instance_double(Empeira::Modules::Installer)
      allow(Empeira::Modules::Installer).to receive(:new).and_return(@installer)
      allow(@installer).to receive(:synchronize) do |request, target, **|
        @installed_requests << request
        names = %w[profile hieradata] - request.data.fetch('overrides')
        (names | request.data.fetch('overrides')).each { |name| target.join(name).mkpath }
        names.each { |name| target.join(name, 'value.txt').write(name) }
        names
      end
    end

    def module_config(required: false)
      { 'hiera' => { 'mounts' => [{ 'type' => 'module', 'name' => 'hieradata',
                                    'source' => './local-data', 'required' => required }] } }
    end

    def sync(config = {})
      plane = controller(config)
      @store.with_lock { updater(plane).synchronize }
      plane
    end

    it 'rejects an absent module tree without invoking r10k or any image acquisition' do
      expect(runtime).not_to receive(:ensure_image)
      expect { mutate(controller, :up) }.to raise_error(Empeira::Error, /Run: empeira update modules/)
      expect(@installed_requests).to be_empty
      expect(runtime.services).to be_empty
    end

    it 'consumes existing modules even after Puppetfile changes without invoking the installer' do
      plane = sync
      File.open(File.join(@directory, 'Puppetfile'), 'a') { |file| file.puts '# changed Puppetfile' }
      expect(@installer).not_to receive(:synchronize)
      expect(runtime).not_to receive(:refresh_image)
      mutate(plane, :up)
      server = runtime.services.fetch('server').fetch('id')
      mutate(controller, :up)
      expect(runtime.services.fetch('server').fetch('id')).to eq(server)
      expect(@store.load.fetch('control_plane')).not_to have_key('modules')
      mounts = Empeira::ControlPlane::Plan.new(context: context).repository_mounts
      expect(mounts).to include("type=bind,src=#{File.realpath(@directory)}/modules," \
                                'dst=/etc/puppetlabs/code/environments/production/modules,readonly')
      expect(Pathname(@directory).join('modules/.empeira')).not_to exist
    end

    it 'keeps local mounts last and uses existing fallback modules when an optional override disappears' do
      config = module_config
      mutate(sync(config), :up)
      expect(@installed_requests.last.data.fetch('overrides')).to eq([])
      FileUtils.mkdir_p(File.join(@directory, 'local-data'))
      mutate(controller(config), :up)
      plan = Empeira::ControlPlane::Plan.new(context: context(config))
      expect(plan.repository_mounts.last)
        .to include('dst=/etc/puppetlabs/code/environments/production/modules/hieradata,readonly')
      FileUtils.rmdir(File.join(@directory, 'local-data'))
      mutate(controller(config), :up)
      expect(@installed_requests.size).to eq(1)
    end

    it 'fails required mounts before fetching or starting a server' do
      expect do
        mutate(controller(module_config(required: true)), :up)
      end.to raise_error(Empeira::ConfigurationError, /required/)
      expect(@installed_requests).to be_empty
      expect(runtime.services).to be_empty
    end

    it 'updates modules in place without requiring runtime activation and preserves them on destroy' do
      plane = sync
      mutate(plane, :up)
      server = runtime.services.fetch('server').fetch('id')
      @store.with_lock { updater(plane).synchronize }
      mutate(plane, :up)
      expect(runtime.services.fetch('server').fetch('id')).to eq(server)
      mutate(plane, :destroy)
      expect(Pathname(@directory).join('modules/profile/value.txt').read).to eq('profile')
      mutate(controller, :up)
      expect(@installed_requests.size).to eq(2)
    end

    it 'changes the live module mount after explicitly synchronizing modules.path' do
      mutate(sync, :up)
      config = { 'modules' => { 'path' => '.cache/custom-modules' } }
      mutate(sync(config), :up)
      expect(Pathname(@directory).join('.cache/custom-modules/profile/value.txt').read).to eq('profile')
      expect(Pathname(@directory).join('modules/profile/value.txt').read).to eq('profile')
    end

    it 'removes the managed module mount when Puppetfile is removed' do
      mutate(sync, :up)
      File.unlink(File.join(@directory, 'Puppetfile'))
      mutate(controller, :up)
      expect(Empeira::ControlPlane::Plan.new(context: context).repository_mounts.size).to eq(1)
    end

    it 'rejects an explicit modulepath exclusion before synchronization' do
      File.write(File.join(@directory, 'environment.conf'), 'modulepath = site:$basemodulepath')
      expect { mutate(controller, :up) }.to raise_error(Empeira::ConfigurationError, /modulepath/)
      expect(@installed_requests).to be_empty
    end

    it 'rejects tracked module contents before invoking r10k' do
      FileUtils.mkdir_p(File.join(@directory, 'modules/profile'))
      File.write(File.join(@directory, 'modules/profile/init.pp'), 'tracked control code')
      Empeira::Execution::Runner.new.run('git', arguments: ['add', '--', 'modules'], directory: @directory)
      expect { sync }.to raise_error(Empeira::Error, /Git-tracked files/)
      expect(@installed_requests).to be_empty
      expect(runtime.services).to be_empty
    end
  end
end
