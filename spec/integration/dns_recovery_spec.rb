# frozen_string_literal: true

RSpec.describe 'DNS recovery with retained nodes', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_DNS_RECOVERY_RUNTIME', 'podman') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }

  def app
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
  let(:plan) do
    Empeira::ControlPlane::Plan.new(context: app.context).tap do |current|
      current.subnet = store.load.fetch('peer_network').fetch('subnet')
    end
  end

  def service(key)
    runtime.inspect_service(plan.definitions.fetch(key),
                            expected_id: store.load.dig('control_plane', 'services', key, 'id'))
  end

  def node
    definition = Empeira::Node::Definition.new(hostname: 'recovery-node', workspace: app.context.workspace)
    runtime.inspect_service(definition, expected_id: store.load.dig('nodes', 'recovery-node', 'id'))
  end

  def check_dns
    code = 'dns = Resolv::DNS.new; dns.timeouts = 3; puts dns.getaddress("server.empeira.internal")'
    result = runtime.service_exec(node, [Empeira::Node::Certificates::RUBY, '-rresolv', '-e', code], timeout: 10)
    expect(result).to be_success, result.stderr
    expect(result.stdout.strip).to eq(service('server').dig('networks', plan.network, 'IPAddress'))
  end

  before do
    skip 'Set EMPEIRA_DNS_RECOVERY_INTEGRATION=1 for real stopped-container recovery' unless
      ENV['EMPEIRA_DNS_RECOVERY_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'dns-recovery': }\n")
    config = { 'puppetdb' => { 'enabled' => false }, 'node_defaults' => { 'version' => '24.04' } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
    runtime.check_available!
    @available = true
  end

  after { app.infrastructure.destroy if @available }

  it 'resumes DNS and gateway without replacing them or invalidating a managed node' do
    app.infrastructure.up
    app.run_node(hostname: 'recovery-node', provider: 'container')
    check_dns
    retained = store.load
    ca = runtime.service_exec(service('server'), %w[sha256sum /etc/puppetlabs/puppet/ssl/certs/ca.pem]).stdout
    expect(ca).to match(/\A[0-9a-f]{64} /)

    # Native stop retains containers but can erase their observed IP addresses, as after an engine/host restart.
    %w[dns gateway].each { |key| runtime.stop_service(service(key)) }
    expect(app.infrastructure.up.changed).to be(true)
    expect(store.load.fetch('nodes')).to eq(retained.fetch('nodes'))
    expect(store.load.dig('control_plane', 'services')).to eq(retained.dig('control_plane', 'services'))
    expect(store.load.dig('control_plane', 'volumes')).to eq(retained.dig('control_plane', 'volumes'))
    %w[dns gateway].each do |key|
      expected = plan.definitions.fetch(key).options.fetch('runtime_ip')
      expect(service(key).dig('networks', plan.network, 'IPAddress')).to eq(expected)
    end
    certificate = runtime.service_exec(service('server'), %w[sha256sum /etc/puppetlabs/puppet/ssl/certs/ca.pem])
    expect(certificate.stdout).to eq(ca)
    check_dns
    expect([0, 2]).to include(app.nodes.puppet(name: 'recovery-node').exit_status)
    expect(app.infrastructure.up.changed).to be(false)
  end
end
