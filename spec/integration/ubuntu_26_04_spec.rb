# frozen_string_literal: true

RSpec.describe 'Real Ubuntu 26.04 nodes', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  let(:app) do
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end
  let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

  def state
    Empeira::Infrastructure::Store.new(context: app.context).load
  end

  def command(provider, arguments)
    record = state.fetch('nodes').fetch("#{provider}-ubuntu")
    return vm_guest(app).run(record, arguments) if provider == 'vm'

    definition = Empeira::Node::Definition.new(hostname: record.fetch('hostname'), workspace: app.context.workspace)
    runtime.service_exec(runtime.inspect_service(definition, expected_id: record.fetch('id')), arguments)
  end

  before do
    skip 'Set EMPEIRA_UBUNTU_26_INTEGRATION=1 for real container and VM Ubuntu 26.04 tests' unless
      ENV['EMPEIRA_UBUNTU_26_INTEGRATION'] == '1'

    initialize_project(project)
    File.write(File.join(project, '.empeira.yaml'), YAML.dump('puppetdb' => { 'enabled' => false }))
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      service { 'puppet': ensure => stopped, enable => false }
      file { '/var/tmp/ubuntu-lts-test': content => 'managed' }
    PUPPET
    runtime.check_available!
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
  end

  after do
    app.infrastructure.destroy if ENV['EMPEIRA_UBUNTU_26_INTEGRATION'] == '1' && File.directory?(project) && state
  end

  it 'installs the pinned agent, enrolls, runs Puppet, resolves DNS and preserves each provider across restart' do
    app.infrastructure.up
    %w[container vm].each do |provider|
      name = "#{provider}-ubuntu"
      app.run_node(hostname: name, provider: provider)
      record = state.fetch('nodes').fetch(name)
      expect(record).to include('os' => 'ubuntu', 'version' => '26.04', 'provisioned' => true)
      expect([0, 2]).to include(record.fetch('last_puppet_exit'))
      expect(command(provider, %w[cat /etc/os-release]).stdout).to include('VERSION_ID="26.04"')
      version = command(provider, [Empeira::Node::Certificates::PUPPET, '--version'])
      expect(version).to be_success, version.stderr
      expect(version.stdout.strip).to eq(app.context.configuration.dig('agent', 'version'))
      expect(command(provider, [Empeira::Node::Certificates::PUPPET, 'ssl', 'verify'])).to be_success
      expect(command(provider, %w[cat /var/tmp/ubuntu-lts-test]).stdout).to eq('managed')
      dns = command(provider, [Empeira::Node::Certificates::RUBY, '-rresolv', '-e',
                               'puts Resolv.getaddress("server.empeira.internal")'])
      expect(dns).to be_success, dns.stderr
      expect(IPAddr.new(dns.stdout.strip)).to be_ipv4
      app.nodes.stop(name: name)
      expect(app.nodes.list).to include(hash_including('hostname' => name, 'state' => 'stopped'))
      app.nodes.start(name: name)
      expect(command(provider, %w[cat /var/tmp/ubuntu-lts-test]).stdout).to eq('managed')
      expect(app.nodes.puppet(name: name).exit_status).to eq(0)
      expect(state.fetch('nodes').fetch(name).slice('id', 'base_image', 'overlay'))
        .to eq(record.slice('id', 'base_image', 'overlay'))
      app.nodes.destroy(name: name)
      expect(state.fetch('nodes')).not_to have_key(name)
    end
  end
end
