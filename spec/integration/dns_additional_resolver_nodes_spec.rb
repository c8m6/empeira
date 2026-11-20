# frozen_string_literal: true

RSpec.describe 'Managed additional resolver DNS in container and VM nodes', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end

  def application
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def state
    Empeira::Infrastructure::Store.new(context: @app.context).load
  end

  def service(key)
    plan = Empeira::ControlPlane::Plan.new(context: @app.context)
    @runtime.inspect_service(plan.definitions.fetch(key),
                             expected_id: state.dig('control_plane', 'services', key, 'id'))
  end

  def fixture_image(corefile)
    defaults = @app.context.configuration
    base = Empeira::Images::Configuration.reference(defaults.dig('images', 'dns'))
    recipe = "FROM #{base}\nCOPY Corefile /Corefile\n# #{Digest::SHA256.hexdigest(corefile)}\n"
    image = Empeira::Images::Configuration.local_image(recipe, purpose: 'dns-fixture')
    @runtime.ensure_image(image, recipe: recipe, files: { 'Corefile' => corefile })
    repository, _, tag = image.rpartition(':')
    { 'repository' => repository, 'tag' => tag }
  end

  def query(provider, name)
    record = state.fetch('nodes').fetch("#{provider}-dns")
    code = 'puts Resolv::DNS.open { |dns| dns.getresources(ARGV[0], Resolv::DNS::Resource::IN::A).map(&:address) }'
    arguments = [Empeira::Node::Certificates::RUBY, '-rresolv', '-e', code, name]
    return vm_guest(@app).run(record, arguments) if provider == 'vm'

    definition = Empeira::Node::Definition.new(hostname: record.fetch('hostname'), workspace: @app.context.workspace)
    @runtime.service_exec(@runtime.inspect_service(definition, expected_id: record.fetch('id')), arguments)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Persist a disposable owned address holder before replacing the resolver.
  def reserve_resolver_address
    plan = Empeira::ControlPlane::Plan.new(context: @app.context)
    resource = service('mockly')
    address = resource.dig('networks', plan.network, 'IPAddress')
    definition = Empeira::Services::Definition.new(
      key: 'dns-ip-reservation', workspace: @app.context.workspace,
      network: plan.network, runtime_ip: address, memory: 64,
      image: plan.definitions.fetch('mockly').options.fetch('image')
    )
    store = Empeira::Infrastructure::Store.new(context: @app.context)
    store.with_lock do
      current = store.load
      @runtime.remove_service(plan.definitions.fetch('mockly'), expected_id: resource.fetch('id'))
      current.fetch('control_plane').fetch('services')[definition.key] = { 'id' => nil }
      store.write(current)
      holder = @runtime.create_service(definition)
      current.fetch('control_plane').fetch('services')[definition.key]['id'] = holder.fetch('id')
      store.write(current)
      @runtime.start_service(holder)
    end
    address
  end

  before do
    skip 'Set EMPEIRA_DNS_NODE_INTEGRATION=1 for real managed-node DNS tests' unless
      ENV['EMPEIRA_DNS_NODE_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'additional-resolver-node': }\n")
    @app = application
    @runtime = Empeira::Runtime.registry.build(engine, context: @app.context, runner: @app.runner)
    @runtime.check_available!
    Empeira::VM.registry.build('qemu', context: @app.context, runner: @app.runner).preflight!
    mockly = fixture_image(<<~'CONFIG')
      .:53 {
        template IN A {
          match "^hit\.example\.test\.$"
          answer "{{ .Name }} 0 IN A 198.51.100.10"
          fallthrough
        }
        template IN A {
          match "^nodata\.example\.test\.$"
          rcode NOERROR
          fallthrough
        }
        template IN ANY {
          rcode NXDOMAIN
        }
        log
      }
    CONFIG
    upstream = fixture_image(<<~CONFIG)
      .:53 {
        template IN A {
          answer "{{ .Name }} 0 IN A 198.51.100.20"
        }
        log
      }
    CONFIG
    @config = { 'puppetdb' => { 'enabled' => false },
                'containers' => { 'additional' => [{ 'name' => 'mockly', 'image' => mockly },
                                                   { 'name' => 'upstream', 'image' => upstream }] } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = application
  end

  after { @app.infrastructure.destroy if @app && state }

  it 'activates the internal resolver through up and serves hits, NXDOMAIN and NODATA fallback to both providers' do
    @app.infrastructure.up
    plan = Empeira::ControlPlane::Plan.new(context: @app.context)
    @config['dns'] = { 'additional_resolver' => 'mockly.empeira.internal' }
    address = service('upstream').dig('networks', plan.network, 'IPAddress')
    allow(Empeira::Platform::Resolvers).to receive(:new).and_wrap_original do |method, **options|
      method.call(**options).tap do |resolver|
        allow(resolver).to receive(:routes).and_return('example.test' => [address])
      end
    end
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = application
    dns_id = service('dns').fetch('id')
    @app.infrastructure.up
    corefile = File.binread(plan.files.path('Corefile'))
    expect(corefile).not_to include('forward . mockly.empeira.internal')
    expect(corefile).to include("forward . #{service('mockly').dig('networks', plan.network, 'IPAddress')} {")
    %w[container vm].each do |provider|
      @app.run_node(hostname: "#{provider}-dns", provider: provider)
      { 'hit' => '198.51.100.10', 'fallback' => '198.51.100.20', 'nodata' => '198.51.100.20' }.each do |name, answer|
        result = query(provider, "#{name}.example.test")
        expect(result).to be_success, result.stderr
        expect(result.stdout.strip).to eq(answer)
      end
    end
    upstream_logs = @runtime.service_logs(service('upstream'))
    expect(upstream_logs).not_to include('hit.example.test.')
    expect(upstream_logs).to include('fallback.example.test.', 'nodata.example.test.')
    records = state.fetch('nodes')
    expect(@app.infrastructure.up.changed).to be(false)
    expect(state.fetch('nodes')).to eq(records)
    expect(service('dns').fetch('id')).to eq(dns_id)
    previous_address = reserve_resolver_address
    expect(@app.infrastructure.up.changed).to be(true)
    current_address = service('mockly').dig('networks', plan.network, 'IPAddress')
    expect(current_address).not_to eq(previous_address)
    expect(File.binread(plan.files.path('Corefile'))).to include("forward . #{current_address} {")
    expect(service('dns').fetch('id')).to eq(dns_id)
    expect(state.fetch('nodes')).to eq(records)
    %w[container vm].each do |provider|
      expect(query(provider, 'hit.example.test').stdout.strip).to eq('198.51.100.10')
    end
    expect(@app.infrastructure.up.changed).to be(false)
    network = Empeira::Network::Definition.new(workspace: @app.context.workspace, policy: Empeira::Network::Policy.new)
    expect(@runtime.verify_isolated_network(network, expected_id: state.dig('resources', 'network', 'id'))).to be(true)
  end
end
