# frozen_string_literal: true

require_relative 'support/service_runtime'

class BootstrapRuntimeFixture < ServiceRuntime
  def stop_service(resource)
    resource['state'] = 'stopped'
  end
end

RSpec.describe Empeira::Network::BootstrapProxy do
  let(:configuration) { {} }
  let(:app) do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(configuration))
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end
  let(:runtime) { BootstrapRuntimeFixture.new }
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context, recovery: true) }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
  let(:proxy) { described_class.new(context: app.context, runtime: runtime, store: store) }
  let(:requirements) { Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04') }
  let(:record) do
    { 'provider' => 'vm', 'hostname' => 'first.test', 'peer' => { 'ip' => '172.20.0.32', 'token' => 'a' * 32 } }
  end
  def state
    store.load
  end

  def initial_state
    { 'schema_version' => 2, 'workspace' => app.context.workspace.id, 'runtime' => 'podman',
      'resources' => {}, 'generation' => 'a' * 32, 'nodes' => { record.fetch('hostname') => record },
      'peer_network' => { 'subnet' => '172.20.0.0/24' },
      'control_plane' => { 'egress' => @egress_id,
                           'services' => { 'gateway' => { 'id' => @gateway_id }, 'dns' => { 'id' => @dns_id } } } }
  end

  def start_proxy(client = record, selected = proxy)
    store.with_operation do |operation|
      operation.attach(client)
      selected.start(state, requirements, source: client.fetch('peer').fetch('ip'))
    end
  end

  context 'with a custom shared memory limit and both regular proxy scopes disabled' do
    let(:configuration) do
      { 'proxy' => { 'memory' => 768, 'nodes' => { 'enabled' => false },
                     'infrastructure' => { 'enabled' => false } } }
    end

    it 'passes the configured limit through the actual temporary proxy creation plan' do
      expect(plan.proxy?).to be(false)
      expect(runtime).to receive(:create_service).and_wrap_original do |create, definition|
        expect(definition.key).to eq('bootstrap-proxy')
        expect(definition.options.fetch('memory')).to eq(768)
        arguments = Empeira::Runtime::ServiceArguments.new(definition).build
        expect(arguments.each_cons(2).to_a).to include(['--memory', '768m'])
        create.call(definition)
      end
      start_proxy
      proxy.cleanup(state)
    end
  end

  before do
    gateway = runtime.create_service(plan.definitions.fetch('gateway'))
    runtime.start_service(gateway)
    @gateway_id = gateway.fetch('id')
    dns = runtime.create_service(plan.definitions.fetch('dns'))
    runtime.start_service(dns)
    @dns_id = dns.fetch('id')
    egress = Empeira::Network::Egress.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
    @egress_id = runtime.create_network(definition: egress).resource.id
    store.with_lock { store.write(initial_state) }
    FileUtils.mkdir_p(plan.files.directory)
    allow(proxy).to receive(:wait_ready)
  end

  it 'authenticates a scoped proxy, records ownership without secrets, and removes it after bootstrap' do
    proxy.preflight!(state)
    endpoint = start_proxy
    expect(endpoint).to match(/\A(?:[0-9]+\.){3}[0-9]+\z/)
    policy = File.read(store.directory.join('bootstrap-proxy/squid.conf').to_s)
    expect(policy).to include('Proxy-Authorization', *requirements.destinations,
                              'http_access deny forbidden')
    expect(policy).not_to include(URI(requirements.repository.fetch('url')).host)
    expect(policy).to include('http_access deny all', ' src 172.20.0.32/32')
    token = URI(proxy.url).password
    expect(policy).to include(["bootstrap:#{token}"].pack('m0'))
    expect(state.to_s).not_to include(token, 'authorization', 'allowlist')
    definition = plan.bootstrap_proxy(dns: '172.20.0.2')
    expect(definition.options.to_s).not_to include(token)
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
    expect(state).not_to have_key('bootstrap_proxy')
    expect(File.exist?(store.directory.join('bootstrap-proxy/squid.conf').to_s)).to be(false)
    expect(proxy.url).to be_nil
  end

  it 'retains cleanup ownership and blocks completion if private policy removal fails' do
    start_proxy
    policy = store.directory.join('bootstrap-proxy/squid.conf').to_s
    client = store.directory.join('bootstrap-proxy/clients').children.fetch(0)
    allow(Empeira::Infrastructure::OwnedFiles).to receive(:remove).and_call_original
    allow(Empeira::Infrastructure::OwnedFiles).to receive(:remove).with(client, root: store.directory).and_raise(Errno::EACCES)
    expect { proxy.cleanup(state) }.to raise_error(Empeira::Error, /credentials.*Puppet was not run/)
    expect(state).to have_key('bootstrap_proxy')
    expect(File.exist?(policy)).to be(true)
    allow(Empeira::Infrastructure::OwnedFiles).to receive(:remove).with(client, root: store.directory).and_call_original
    proxy.cleanup(state)
    expect(state).not_to have_key('bootstrap_proxy')
    expect(File.exist?(policy)).to be(false)
  end

  it 'rejects unexpected external port bindings and allows owned cleanup after failure' do
    proxy.preflight!(state)
    allow(runtime).to receive(:inspect_service).and_wrap_original do |original, definition, **options|
      resource = original.call(definition, **options)
      if definition.key == 'bootstrap-proxy' && resource && resource['state'] == 'running'
        resource['published_ports'] = { '3128/tcp' => [{ 'HostIp' => '0.0.0.0', 'HostPort' => '32123' }] }
      end
      resource
    end
    expect do
      start_proxy
    end.to raise_error(Empeira::Providers::OwnershipError, /published ports/)
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
  end

  it 'preserves unrelated user proxy policy during bootstrap cleanup' do
    runtime.services['proxy'] = { 'id' => 'user-proxy' }
    proxy.preflight!(state)
    start_proxy
    proxy.cleanup(state)
    expect(runtime.services['proxy']).to eq('id' => 'user-proxy')
  end

  it 'recovers owned creation with an uncertain result without deleting unrelated services' do
    proxy.preflight!(state)
    runtime.failure = 'bootstrap-proxy'
    expect { start_proxy }
      .to raise_error(Empeira::Providers::ExecutionError)
    expect(state).to have_key('bootstrap_proxy')
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
    expect(runtime.services).to have_key('dns')
  end
  it 'attempts a stop if removal fails, retaining inventory for recovery' do
    proxy.preflight!(state)
    start_proxy
    allow(runtime).to receive(:remove_service).and_raise(Empeira::Providers::ExecutionError, 'removal failed')
    expect(runtime).to receive(:stop_service).with(hash_including('state' => 'running'))
    expect { proxy.cleanup(state) }.to raise_error(Empeira::Providers::ExecutionError, /removal failed/)
    expect(state).to have_key('bootstrap_proxy')
  end

  it 'preserves the other source/auth grant when one concurrent client finishes' do
    other = record.merge('hostname' => 'second.test', 'peer' => { 'ip' => '172.20.0.33', 'token' => 'b' * 32 })
    current = state
    current.fetch('nodes')[other.fetch('hostname')] = other
    store.write(current)
    second = described_class.new(context: app.context, runtime: runtime, store: store)
    allow(second).to receive(:wait_ready)
    start_proxy
    start_proxy(other, second)
    id = state.fetch('bootstrap_proxy').fetch('id')
    tokens = [proxy, second].map { |client| ["bootstrap:#{URI(client.url).password}"].pack('m0') }
    policy = Pathname(store.directory.join('bootstrap-proxy/squid.conf').to_s)
    expect(policy.read).to include(*tokens, '172.20.0.32/32', '172.20.0.33/32')
    proxy.cleanup(state)
    expect(state.fetch('bootstrap_proxy').fetch('id')).to eq(id)
    expect(policy.read).to include(tokens.last, '172.20.0.33/32')
    expect(policy.read).not_to include(tokens.first, '172.20.0.32/32')
    second.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
  end

  it 'revokes only the old instance when its address and hostname are reused' do
    start_proxy
    old_token = ["bootstrap:#{URI(proxy.url).password}"].pack('m0')
    replacement = record.merge('peer' => record.fetch('peer').merge('token' => 'c' * 32))
    current = state
    current.fetch('nodes')[replacement.fetch('hostname')] = replacement
    store.write(current)
    second = described_class.new(context: app.context, runtime: runtime, store: store)
    allow(second).to receive(:wait_ready)
    start_proxy(replacement, second)
    new_token = ["bootstrap:#{URI(second.url).password}"].pack('m0')
    proxy.cleanup(state)
    content = File.read(store.directory.join('bootstrap-proxy/squid.conf').to_s)
    expect(content).to include(new_token)
    expect(content).not_to include(old_token)
    expect(state).to have_key('bootstrap_proxy')
    second.cleanup(state)
  end

  it 'refuses to reuse an incompatible proxy definition and removes legacy credentials on cleanup' do
    start_proxy
    resource = runtime.services.fetch('bootstrap-proxy')
    resource.fetch('labels')['io.empeira.definition'] = 'legacy-definition'
    legacy = Pathname(plan.files.path('bootstrap-squid.conf'))
    legacy.write('synthetic obsolete credential policy')
    expect { start_proxy }.to raise_error(Empeira::Error, /definition changed/)
    proxy.cleanup(state)
    expect(legacy).not_to exist
    expect(runtime.services).not_to have_key('bootstrap-proxy')
  end

  it 'retains the last native HTTP response when the existing readiness deadline expires' do
    allow(proxy).to receive(:wait_ready).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0, 31)
    failed = Empeira::Execution::Result.new(stdout: '', stderr: 'HTTP/1.1 502 Synthetic proxy failure',
                                            exit_status: 1, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(failed)
    expect { proxy.send(:wait_ready, state, '172.20.0.10') }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('Operation: Bootstrap proxy readiness', 'http://bootstrap.invalid/',
                                         'HTTP/1.1 502 Synthetic proxy failure')
      end
  end
end
