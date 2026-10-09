# frozen_string_literal: true

require_relative 'support/service_runtime'

class BootstrapRuntimeFixture < ServiceRuntime
  def stop_service(resource)
    resource['state'] = 'stopped'
  end
end

RSpec.describe Empeira::Network::BootstrapProxy do
  let(:app) do
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end
  let(:runtime) { BootstrapRuntimeFixture.new }
  let(:store) { instance_double(Empeira::Infrastructure::Store, write: nil) }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
  let(:proxy) { described_class.new(context: app.context, runtime: runtime, store: store) }
  let(:requirements) { Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04') }
  let(:record) { { 'peer' => { 'ip' => '172.20.0.32' } } }
  let(:state) do
    { 'peer_network' => { 'subnet' => '172.20.0.0/24' },
      'control_plane' => { 'egress' => @egress_id,
                           'services' => { 'gateway' => { 'id' => @gateway_id }, 'dns' => { 'id' => @dns_id } } } }
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
    FileUtils.mkdir_p(plan.files.directory)
    allow(proxy).to receive(:wait_ready)
  end

  it 'authenticates a scoped proxy, records ownership without secrets, and removes it after bootstrap' do
    proxy.preflight!(state)
    endpoint = proxy.start(state, requirements, source: record.fetch('peer').fetch('ip'))
    expect(endpoint).to match(/\A(?:[0-9]+\.){3}[0-9]+\z/)
    policy = File.read(plan.files.path('bootstrap-squid.conf'))
    expect(policy).to include('Proxy-Authorization', 'archive.ubuntu.com',
                              'http_access deny forbidden')
    expect(policy).not_to include(URI(requirements.repository.fetch('url')).host)
    expect(policy).to include('http_access deny !clients', 'http_access deny all',
                              'acl provisioning_vm src 172.20.0.32/32', 'http_access deny !provisioning_vm')
    token = URI(proxy.url).password
    expect(policy).to include(["bootstrap:#{token}"].pack('m0'))
    expect(state.to_s).not_to include(token, 'authorization', 'allowlist')
    definition = plan.bootstrap_proxy(dns: '172.20.0.2')
    expect(definition.options.to_s).not_to include(token)
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
    expect(state).not_to have_key('bootstrap_proxy')
    expect(File.exist?(plan.files.path('bootstrap-squid.conf'))).to be(false)
    expect(proxy.url).to be_nil
  end

  it 'retains cleanup ownership and blocks completion if private policy removal fails' do
    proxy.start(state, requirements, source: record.fetch('peer').fetch('ip'))
    policy = plan.files.path('bootstrap-squid.conf')
    allow(File).to receive(:unlink).and_call_original
    allow(File).to receive(:unlink).with(policy).and_raise(Errno::EACCES)
    expect { proxy.cleanup(state) }.to raise_error(Empeira::Error, /credentials.*Puppet was not run/)
    expect(state).to have_key('bootstrap_proxy')
    expect(File.exist?(policy)).to be(true)
    allow(File).to receive(:unlink).with(policy).and_call_original
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
      proxy.start(state, requirements, source: record.fetch('peer').fetch('ip'))
    end.to raise_error(Empeira::Providers::OwnershipError, /published ports/)
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
  end

  it 'preserves unrelated user proxy policy during bootstrap cleanup' do
    runtime.services['proxy'] = { 'id' => 'user-proxy' }
    proxy.preflight!(state)
    proxy.start(state, requirements, source: record.fetch('peer').fetch('ip'))
    proxy.cleanup(state)
    expect(runtime.services['proxy']).to eq('id' => 'user-proxy')
  end

  it 'recovers owned creation with an uncertain result without deleting unrelated services' do
    proxy.preflight!(state)
    runtime.failure = 'bootstrap-proxy'
    expect { proxy.start(state, requirements, source: record.fetch('peer').fetch('ip')) }
      .to raise_error(Empeira::Providers::ExecutionError)
    expect(state).to have_key('bootstrap_proxy')
    proxy.cleanup(state)
    expect(runtime.services).not_to have_key('bootstrap-proxy')
    expect(runtime.services).to have_key('dns')
  end
  it 'attempts a stop if removal fails, retaining inventory for recovery' do
    proxy.preflight!(state)
    proxy.start(state, requirements, source: record.fetch('peer').fetch('ip'))
    allow(runtime).to receive(:remove_service).and_raise(Empeira::Providers::ExecutionError, 'removal failed')
    expect(runtime).to receive(:stop_service).with(hash_including('state' => 'running'))
    expect { proxy.cleanup(state) }.to raise_error(Empeira::Providers::ExecutionError, /removal failed/)
    expect(state).to have_key('bootstrap_proxy')
  end
end
