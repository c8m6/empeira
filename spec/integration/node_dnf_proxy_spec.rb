# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'

RSpec.describe 'Real DNF runtime proxy', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:hostname) { 'dnf-node.example.test' }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end

  def app
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  before do
    skip 'Set EMPEIRA_DNF_RUNTIME_INTEGRATION=1 for real DNF package checks' unless
      ENV['EMPEIRA_DNF_RUNTIME_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    os = 'rocky'
    version = ENV.fetch('EMPEIRA_DNF_GUEST_VERSION', '9')
    guest = app.context.configuration.dig('bootstrap', 'guests', os, version)
    @config = { 'puppetdb' => { 'enabled' => false }, 'node_defaults' => { 'os' => os, 'version' => version },
                'proxy' => { 'enabled' => true, 'global' => guest.fetch('destinations') } }
    write_configuration
    architecture = Empeira::VM::ImageSource::ARCHITECTURES.fetch(app.context.platform.architecture.to_s)
    @baseurl = "#{guest.fetch('baseurl')}/BaseOS/#{architecture}/os/"
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'dnf-proxy-ready': }\n")
    @runtime = Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner)
    @runtime.check_available!
  end

  after do
    next unless ENV['EMPEIRA_DNF_RUNTIME_INTEGRATION'] == '1' && File.directory?(project)

    app.infrastructure.destroy if Empeira::Infrastructure::Store.new(context: app.context).load
  end

  %w[container vm].each do |provider|
    it "installs through Puppet and preserves DNF repositories across proxy reconciliation on #{provider}" do
      selected = ENV.fetch('EMPEIRA_RUNTIME_MANAGEMENT_PROVIDERS', 'container,vm').split(',')
      skip "Provider #{provider} not selected" unless selected.include?(provider)

      @provider = provider
      Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight! if provider == 'vm'
      app.infrastructure.up
      app.run_node(hostname: hostname, provider: provider)
      install_package_manifest
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
      if provider == 'vm'
        expect(guest(%w[getenforce]).stdout.strip).to eq('Enforcing')
        expect(guest(['ls', '-Zd', '/run/empeira-management-ssh']).stdout).to include('sshd_var_run_t')
      end
      expect(guest(%w[tree --version])).to be_success
      expect(guest(['test', '!', '-e', Empeira::Node::PackageProxy::DNF_PATH])).to be_success
      expect(guest(['test', '!', '-e', Empeira::Node::RpmConfiguration::BACKUP])).to be_success
      sources = guest(['sh', '-c', 'sha256sum /etc/yum.repos.d/*.repo']).stdout
      config = guest(%w[cat /etc/dnf/dnf.conf]).stdout
      expect(config).to include('proxy=http://proxy.empeira.internal:3128')
      expect(config).not_to match(/proxy_(?:username|password)=/)
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
      app.nodes.stop(name: hostname)
      app.nodes.start(name: hostname)
      expect(guest(['dnf', '--disablerepo=*', '--enablerepo=runtime-dnf-test', 'makecache'])).to be_success
      @config['proxy']['enabled'] = false
      write_configuration
      app.infrastructure.up
      expect(guest(%w[cat /etc/dnf/dnf.conf]).stdout).not_to include('proxy=http://proxy.empeira.internal:3128')
      @config['proxy']['enabled'] = true
      write_configuration
      app.infrastructure.up
      expect(guest(['sh', '-c', 'sha256sum /etc/yum.repos.d/*.repo']).stdout).to eq(sources)
      expect(guest(['dnf', '--disablerepo=*', '--enablerepo=runtime-dnf-test', 'makecache'])).to be_success
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
    end
  end

  def install_package_manifest
    key = native_gpgkey
    # Puppet owns this additional repository; signing metadata comes from native sources.
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      yumrepo { 'runtime-dnf-test':
        ensure => present, enabled => 1, gpgcheck => 1, descr => 'Runtime DNF integration fixture',
        baseurl => '#{@baseurl}', gpgkey => '#{key}',
      }
      package { 'tree': ensure => installed,
        install_options => ['--disablerepo=*', '--enablerepo=runtime-dnf-test'],
        require => Yumrepo['runtime-dnf-test'],
      }
    PUPPET
  end

  def native_gpgkey
    source = <<~'RUBY'
      sources = Dir.glob('/etc/yum.repos.d/*.repo').map { |path| File.read(path) }.join("\n")
      section = sources[/^\[baseos\]\s*\n(.*?)(?=^\[|\z)/m, 1]
      puts section[/^\s*gpgkey\s*=\s*(\S+)/, 1]
    RUBY
    key = guest([Empeira::Node::Certificates::RUBY, '-e', source]).stdout.strip
    expect(key).to match(%r{\Afile:///etc/pki/rpm-gpg/[a-zA-Z0-9_.-]+\z})
    key
  end

  def write_configuration
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
  end

  def guest(arguments)
    if @provider == 'vm'
      management_ssh.run(record, arguments, timeout: 300)
    else
      definition = Empeira::Node::Definition.new(hostname: hostname, workspace: app.context.workspace)
      @runtime.service_exec(@runtime.inspect_service(definition), arguments, timeout: 300)
    end
  end

  def record
    Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch(hostname)
  end

  def management_ssh
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
  end
end
