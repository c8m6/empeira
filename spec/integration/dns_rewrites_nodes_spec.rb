# frozen_string_literal: true

RSpec.describe 'DNS rewrites in managed container and VM nodes', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }

  def rewrite_app
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                 environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def rewrite_state
    Empeira::Infrastructure::Store.new(context: @app.context).load
  end

  def node_query(provider, name, type = 'A')
    code = 'puts Resolv::DNS.open { |dns| dns.getresources(ARGV[0], ' \
           'Resolv::DNS::Resource::IN.const_get(ARGV[1])).map ' \
           '{ |r| r.respond_to?(:address) ? r.address.to_s : r.name.to_s } }'
    arguments = [Empeira::Node::Certificates::RUBY, '-rresolv', '-e', code, name, type]
    node_command(provider, arguments)
  end

  def node_command(provider, arguments)
    record = rewrite_state.fetch('nodes').fetch("#{provider}-dns")
    if provider == 'vm'
      vm_guest(@app).run(
        record, arguments
      )
    else
      definition = Empeira::Node::Definition.new(hostname: record.fetch('hostname'), workspace: @app.context.workspace)
      resource = @runtime.inspect_service(definition, expected_id: record.fetch('id'))
      @runtime.service_exec(resource, arguments, timeout: 15)
    end
  end

  def check_node_answers(expected)
    %w[container vm].each do |provider|
      { 'A' => expected, 'AAAA' => '', 'CNAME' => '' }.each do |type, answer|
        result = node_query(provider, 'ipam.example.test', type)
        expect(result).to be_success, result.stderr
        expect(result.stdout.strip).to eq(answer)
      end
    end
  end

  def service_address(key)
    plan = Empeira::ControlPlane::Plan.new(context: @app.context)
    @runtime.inspect_service(plan.definitions.fetch(key)).dig('networks', plan.network, 'IPAddress')
  end

  before do
    skip 'Set EMPEIRA_DNS_NODE_INTEGRATION=1 on an accelerated host for managed-node DNS tests' unless
      ENV['EMPEIRA_DNS_NODE_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'dns-rewrite-node': }\n")
    @config = { 'puppetdb' => { 'enabled' => false } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = rewrite_app
    @runtime = Empeira::Runtime.registry.build(engine, context: @app.context, runner: @app.runner)
    @runtime.check_available!
    Empeira::VM.registry.build('qemu', context: @app.context, runner: @app.runner).preflight!
    request = Empeira::Node::RunRequest.from_config(hostname: 'fixture', config: @app.context.configuration,
                                                    provider: 'container')
    image = Empeira::Node::Image.new(config: @app.context.configuration, request: request,
                                     architecture: @runtime.architecture)
    @runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
    repository, _, tag = image.reference.rpartition(':')
    @config['containers'] = { 'additional' => [{ 'name' => 'api-layer',
                                                 'image' => { 'repository' => repository, 'tag' => tag },
                                                 'command' => %w[sleep infinity] }] }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = rewrite_app
  end

  after do
    next unless @app && rewrite_state

    @app.infrastructure.destroy
    expect(rewrite_state).to be_nil
  end

  it 'reloads rewrites through up without restarting existing managed nodes or the DNS service' do
    @app.infrastructure.up
    %w[container vm].each { |provider| @app.run_node(hostname: "#{provider}-dns", provider: provider) }
    before = rewrite_state
    rule = { 'from' => 'ipam.example.test', 'to' => 'api-layer.empeira.internal' }
    [rule, rule.merge('to' => 'server.empeira.internal')].each do |desired|
      @config['dns'] = { 'rewrites' => [desired] }
      File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
      @app = rewrite_app
      @app.infrastructure.up
      expected = service_address(desired.fetch('to').delete_suffix('.empeira.internal'))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        break if node_query('vm', 'ipam.example.test').stdout.strip == expected
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise 'Managed nodes did not receive the DNS reload'
        end

        sleep 0.2
      end
      check_node_answers(expected)
      expect(rewrite_state.fetch('nodes')).to eq(before.fetch('nodes'))
      expect(rewrite_state.dig('control_plane', 'services')).to eq(before.dig('control_plane', 'services'))
      @app.infrastructure.up
      expect(rewrite_state.fetch('nodes')).to eq(before.fetch('nodes'))
    end
    @config['dns']['rewrites'] = []
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = rewrite_app
    @app.infrastructure.up
    %w[container vm].each do |provider|
      expect(node_query(provider, 'ipam.example.test').stdout.strip).to eq('')
    end
    expect(rewrite_state.fetch('nodes')).to eq(before.fetch('nodes'))
  end
end
