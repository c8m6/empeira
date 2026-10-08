# frozen_string_literal: true

require_relative '../support/proxy_fixture'

RSpec.describe 'Real accelerated VM proxy policy', :integration do
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') }) }
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:app) do
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  before do
    skip 'Set EMPEIRA_VM_PROXY_INTEGRATION=1 for real accelerated VM proxy tests' unless
      ENV['EMPEIRA_VM_PROXY_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'vm-proxy-policy': }\n")
    @runtime = Empeira::Runtime.registry.build(app.context.container_engine, context: app.context, runner: app.runner)
    @runtime.check_available!
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
    @fixture = ProxyFixture.new(app: app, runtime: @runtime, directory: @directory)
    @fixture.start
    @config = { 'puppetdb' => { 'enabled' => false },
                'proxy' => { 'enabled' => true, 'global' => ['allowed.test'],
                             'rules' => [{ 'hosts' => ['*-web-*'], 'allow' => ['denied.test'] }] } }
    configured.infrastructure.up
    # Keep real upstream DNS during package installation, then use only synthetic destinations.
    request = Empeira::Node::RunRequest.from_config(hostname: 'lab-web-vm.test', provider: 'vm',
                                                    config: @configured.context.configuration)
    @configured.nodes.run(request)
  end

  after do
    next unless ENV['EMPEIRA_VM_PROXY_INTEGRATION'] == '1'

    @fixture&.stop
    (@configured || app).infrastructure.destroy if File.directory?(project)
  end

  def configured
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @configured = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  it 'enforces hostname rules over the direct VM lease and reloads only the proxy for a running VM' do
    state = Empeira::Infrastructure::Store.new(context: app.context).load
    record = state.fetch('nodes').fetch('lab-web-vm.test')
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    ssh = Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
    # Add synthetic DNS records through the owned live discovery file without replacing guest DNS bindings.
    files = Empeira::ControlPlane::Files.new(context: app.context)
    hosts = files.directory.join('hosts')
    fixture_hosts = "\n#{@fixture.dns_address.sub(/\.3\z/, '.2')} allowed.test denied.test\n"
    fixture_hosts += "127.0.0.1 private.test\n"
    hosts.write(hosts.read + fixture_hosts)
    sleep 3
    curl = %w[curl --silent --show-error --fail --max-time 10 --proxy http://proxy.empeira.internal:3128 --noproxy
              localhost]
    response = ssh.run(record, [*curl, 'http://denied.test'])
    expect(response).to be_success, response.stderr
    expect(response.stdout).to eq('fixture')
    ssh.copy_to(record, @fixture.ca_path, '/home/empeira/fixture-ca.pem')
    expect(ssh.run(record,
                   [*curl, '--cacert', '/home/empeira/fixture-ca.pem', 'https://allowed.test']).stdout).to eq('fixture')
    expect(ssh.run(record, [*curl, 'http://private.test'])).not_to be_success
    lease = record.fetch('peer')
    @config['proxy']['rules'] = []
    configured.infrastructure.up
    hosts.write(hosts.read + fixture_hosts)
    sleep 3
    expect(ssh.run(record, [*curl, 'http://denied.test'])).not_to be_success
    expect(ssh.run(record, [*curl, 'http://allowed.test']).stdout).to eq('fixture')
    expect(Empeira::Infrastructure::Store.new(context: app.context).load.dig('nodes', 'lab-web-vm.test',
                                                                             'peer')).to eq(lease)
  end
end
