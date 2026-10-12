# frozen_string_literal: true

require_relative '../support/dns_redirect_wire'

RSpec.describe 'Real CoreDNS UDP/TCP redirects', :integration do
  include DNSRedirectWire

  let(:engine) { ENV.fetch('EMPEIRA_DNS_REDIRECT_RUNTIME', 'docker') }
  def project
    @project ||= File.join(@directory, 'control')
  end
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  def app
    @app ||= Empeira::Application.new(project_path: project, locations: locations,
                                      overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def runtime
    @runtime ||= Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner)
  end

  def state
    Empeira::Infrastructure::Store.new(context: app.context).load
  end

  def service(key)
    definition = Empeira::ControlPlane::Plan.new(context: app.context).definitions.fetch(key)
    runtime.inspect_service(definition, expected_id: state.dig('control_plane', 'services', key, 'id'))
  end

  def server
    service('server')
  end

  def reconcile
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = @runtime = nil
    app.infrastructure.up
  end

  before do
    skip 'Set EMPEIRA_DNS_REDIRECT_INTEGRATION=1 for real CoreDNS redirect lifecycle' unless
      ENV['EMPEIRA_DNS_REDIRECT_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), '')
    # The initial offline upstream avoids test DNS requests to host/corporate resolvers.
    @config = { 'puppetdb' => { 'enabled' => false }, 'network' => { 'redirects' => dns_rules },
                'dns' => { 'upstream' => { 'mode' => 'explicit', 'servers' => ['192.0.2.53'] } } }
    reconcile
    prepare_upstream
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Create and verify one owned synthetic upstream.
  def prepare_upstream
    gateway = Empeira::ControlPlane::Plan.new(context: app.context).gateway_artifact
    egress = Empeira::Network::Egress.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
    @upstream_definition = Empeira::Services::Definition.new(
      key: "test-upstream-#{SecureRandom.hex(8)}", workspace: app.context.workspace,
      image: gateway.fetch(:image), network: egress.backend_name, memory: 64,
      entrypoint: '/usr/local/bin/ruby', command: ['-e', DNSRedirectWire::UPSTREAM],
      cap_drop: ['ALL'], cap_add: ['NET_BIND_SERVICE']
    )
    @upstream = runtime.create_service(@upstream_definition)
    runtime.start_service(@upstream)
    observed = runtime.inspect_service(@upstream_definition, expected_id: @upstream.fetch('id'))
    expect(observed.fetch('networks').keys).to eq([egress.backend_name])
    expect(observed.fetch('ports')).to be_empty
    readiness = runtime.service_exec(observed, ['/usr/local/bin/ruby', '-e', DNSRedirectWire::CLIENT,
                                                'udp', '127.0.0.1', 'public.example.test'], timeout: 10)
    expect(readiness).to be_success, readiness.stderr
    expect(JSON.parse(readiness.stdout)).to include('rcode' => 0, 'addresses' => ['192.0.2.1'])
    @config['dns']['upstream']['servers'] = [observed.dig('networks', egress.backend_name, 'IPAddress')]
    reconcile
  end

  after do
    runtime.remove_service(@upstream_definition, expected_id: @upstream.fetch('id')) if @upstream
    if @config
      Empeira::Application.new(project_path: project, locations: locations,
                               recovery: true).infrastructure.destroy
    end
  end

  it 'preserves DNS semantics, native fallback and fail-closed behavior across lifecycle changes' do
    %w[udp tcp].each do |protocol|
      internal = dns_query(protocol, 'server.empeira.internal')
      expect(internal.fetch('rcode')).to eq(0)
      network = Empeira::ControlPlane::Plan.new(context: app.context).network
      expect(internal.fetch('addresses')).to eq([server.dig('networks', network, 'IPAddress')])
      %w[public.example.test apps.corp.example.test].each do |name|
        expect(dns_query(protocol, name)).to include('rcode' => 0, 'addresses' => ['192.0.2.1'])
      end
      expect(dns_query(protocol, 'missing.example.test')).to include('rcode' => 3)
    end
    expect(dns_query('auto', 'large.example.test')).to include('rcode' => 0, 'transport' => 'tcp')
    expect(dns_query('tcp', 'large.example.test').fetch('addresses').size).to eq(80)
    expect(reconcile.changed).to be(false)
    dns = service('dns')
    runtime.stop_service(dns)
    %w[udp tcp].each do |protocol|
      result = runtime.service_exec(server, [Empeira::Node::Certificates::RUBY, '-e', DNSRedirectWire::CLIENT,
                                             protocol, '198.18.0.53', 'public.example.test'], timeout: 10)
      expect(result).not_to be_success
    end
    reconcile
    expect(dns_query('udp', 'public.example.test').fetch('rcode')).to eq(0)
    original = state.dig('control_plane', 'services', 'dns', 'id')
    definition = Empeira::ControlPlane::Plan.new(context: app.context).definitions.fetch('dns')
    runtime.remove_service(definition, expected_id: original)
    reconcile
    expect(state.dig('control_plane', 'services', 'dns', 'id')).not_to eq(original)
    expect(dns_query('tcp', 'public.example.test').fetch('rcode')).to eq(0)
    @config['network']['redirects'] = []
    reconcile
    denied = runtime.service_exec(server, [Empeira::Node::Certificates::RUBY, '-e', DNSRedirectWire::CLIENT,
                                           'udp', '198.18.0.53', 'public.example.test'], timeout: 10)
    expect(denied).not_to be_success
    @config['network']['redirects'] = dns_rules
    reconcile
    expect(dns_query('udp', 'public.example.test').fetch('rcode')).to eq(0)
    recreate_workspace
  end
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Verify a complete second isolated workspace lifecycle.
  def recreate_workspace
    old_address = service('dns').dig('networks', Empeira::ControlPlane::Plan.new(context: app.context).network,
                                     'IPAddress')
    old_subnet = state.dig('peer_network', 'subnet')
    runtime.remove_service(@upstream_definition, expected_id: @upstream.fetch('id'))
    @upstream = nil
    app.infrastructure.destroy
    @project = File.join(@directory, 'other-control')
    @app = @runtime = nil
    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), '')
    @config['dns']['upstream']['servers'] = ['192.0.2.53']
    reconcile
    expect(state.dig('peer_network', 'subnet')).not_to eq(old_subnet)
    new_address = service('dns').dig('networks', Empeira::ControlPlane::Plan.new(context: app.context).network,
                                     'IPAddress')
    expect(new_address).not_to eq(old_address)
    prepare_upstream
    %w[udp tcp].each { |protocol| expect(dns_query(protocol, 'public.example.test')).to include('rcode' => 0) }
    expect(reconcile.changed).to be(false)
  end
end
