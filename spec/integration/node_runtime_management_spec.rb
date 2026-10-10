# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'

RSpec.describe 'Real node runtime management', :integration do
  let(:engine_name) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:hostname) { 'runtime-node.example.test' }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end

  def app
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine_name } })
  end

  before do
    skip 'Set EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION=1 for real package and runtime management checks' unless
      ENV['EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    destinations = app.context.configuration.dig('bootstrap', 'guests', 'ubuntu', '24.04', 'destinations')
    @config = { 'puppetdb' => { 'enabled' => false }, 'vm' => { 'disk' => 30 },
                'proxy' => { 'enabled' => true, 'global' => destinations } }
    write_configuration
    @runtime = Empeira::Runtime.registry.build(engine_name, context: app.context, runner: app.runner)
    @runtime.check_available!
  end

  after do
    next unless ENV['EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION'] == '1' && File.directory?(project)

    app.infrastructure.destroy if Empeira::Infrastructure::Store.new(context: app.context).load
  end

  %w[container vm].each do |provider|
    it "installs a package through Puppet's normal proxy and reconciles retained #{provider} nodes" do
      selected = ENV.fetch('EMPEIRA_RUNTIME_MANAGEMENT_PROVIDERS', 'container,vm').split(',')
      skip "Provider #{provider} not selected" unless selected.include?(provider)

      @provider = provider
      Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight! if provider == 'vm'
      File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
        exec { 'runtime-package-index':
          command => '/usr/bin/apt-get update',
          unless => '/usr/bin/test -e /tmp/empeira-package-index',
          before => Package['tree'],
        }
        package { 'tree': ensure => installed }
        file { '/tmp/empeira-package-index': ensure => file, require => Package['tree'] }
      PUPPET
      app.infrastructure.up
      app.run_node(hostname: hostname, provider: provider)
      expect(guest(%w[tree --version]).stdout).to include('tree')
      expect(guest(['test', '!', '-e', Empeira::Node::PackageProxy::APT_PATH])).to be_success
      Empeira::Node::PackageSources.verify!(execute: ->(arguments) { guest(arguments) })
      identity = record.slice('id', 'pid', 'peer', 'overlay')
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
      app.nodes.stop(name: hostname)
      app.nodes.start(name: hostname)
      expect(guest(%w[tree --version])).to be_success
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
      @config['proxy']['enabled'] = false
      write_configuration
      app.infrastructure.up
      expect(guest(['test', '!', '-e', Empeira::RuntimeProxyGuest::APT_PATH])).to be_success
      @config['proxy']['enabled'] = true
      write_configuration
      app.infrastructure.up
      expect(guest(%w[apt-get update])).to be_success
      expect(record.slice('id', 'peer', 'overlay')).to eq(identity.slice('id', 'peer', 'overlay'))
    end
  end

  def write_configuration
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
  end

  def record
    Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch(hostname)
  end

  def guest(arguments)
    if @provider == 'vm'
      management_ssh.run(record, arguments, timeout: 300)
    else
      definition = Empeira::Node::Definition.new(hostname: hostname, workspace: app.context.workspace)
      @runtime.service_exec(@runtime.inspect_service(definition), arguments, timeout: 300)
    end
  end

  def management_ssh
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
  end
end
