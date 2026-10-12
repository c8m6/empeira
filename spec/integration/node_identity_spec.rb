# frozen_string_literal: true

require_relative '../support/dns_redirect_wire'

RSpec.describe 'Native node FQDN and Hiera identity', :integration do
  include DNSRedirectWire

  let(:engine) { ENV.fetch('EMPEIRA_NODE_IDENTITY_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  let(:app) do
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def command(name, arguments)
    output = Tempfile.new('identity-output')
    result = app.nodes.exec(name: name, arguments: arguments, output: output)
    expect(result).to be_success
    output.rewind
    output.read.strip
  ensure
    output&.close!
  end

  before do
    skip 'Set EMPEIRA_NODE_IDENTITY_INTEGRATION=1 for real Ubuntu container/VM identity checks' unless
      ENV['EMPEIRA_NODE_IDENTITY_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    FileUtils.mkdir_p(File.join(project, 'data/virtual'))
    File.write(File.join(project, '.empeira.yaml'),
               YAML.dump('puppetdb' => { 'enabled' => false }, 'network' => { 'redirects' => dns_rules }))
    hierarchy = [{ 'name' => 'Provider', 'path' => 'virtual/empeira-%{facts.empeira.provider}.yaml' },
                 { 'name' => 'Empeira common', 'path' => 'virtual/%{facts.empeira.hierarchy}.yaml' },
                 { 'name' => 'Virtualization', 'path' => 'virtual/%{facts.virtual}.yaml' }]
    File.write(File.join(project, 'hiera.yaml'), YAML.dump('version' => 5,
                                                           'defaults' => { 'datadir' => 'data',
                                                                           'data_hash' => 'yaml_data' },
                                                           'hierarchy' => hierarchy))
    %w[vm container].each do |provider|
      File.write(File.join(project, "data/virtual/empeira-#{provider}.yaml"),
                 YAML.dump('identity::priority' => provider))
    end
    File.write(File.join(project, 'data/virtual/empeira.yaml'), YAML.dump('identity::common' => 'empeira-only'))
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      file { '/var/lib/hiera-identity': content => [lookup('identity::priority'), lookup('identity::common')].join(',') }
    PUPPET
    @host_hostname = File.read('/etc/hostname') if File.file?('/etc/hostname')
    @host_hosts = File.read('/etc/hosts')
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
    app.infrastructure.up
  end

  after do
    next unless @host_hosts

    Empeira::Application.new(project_path: project, locations: locations, recovery: true).infrastructure.destroy
    expect(File.read('/etc/hosts')).to eq(@host_hosts)
    expect(File.read('/etc/hostname')).to eq(@host_hostname) if @host_hostname
  end

  it 'retains FQDN, native facts, certname and Hiera selection across restart and legacy fact upgrades' do
    %w[container vm].each do |provider|
      name = "#{provider}-node.lab.example.test"
      app.run_node(hostname: name, provider: provider)
      verify_identity(name, provider)
      expect(app.infrastructure.up.changed).to be(false)
      app.nodes.stop(name: name)
      app.nodes.start(name: name)
      verify_identity(name, provider)
      # Simulate a pre-selector inventory/file, then upgrade it through the ordinary lifecycle.
      code = 'File.write(ARGV[0], ARGV[1])'
      command(name, [Empeira::Node::Certificates::RUBY, '-e', code, Empeira::Node::ExternalFact::PATH,
                     "empeira:\n  provider: #{provider}\n"])
      store = Empeira::Infrastructure::Store.new(context: app.context)
      store.with_lock do
        state = store.load
        state.fetch('nodes').fetch(name).delete('empeira_fact')
        store.write(state)
      end
      expect(app.infrastructure.up.changed).to be(true)
      expect(app.infrastructure.up.changed).to be(false)
      verify_identity(name, provider)
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Assert native provider identity and virtual DNS.
  def verify_identity(name, provider)
    expect(command(name, ['hostname'])).to eq(name)
    expect(command(name, %w[hostname -f])).to eq(name)
    facts = JSON.parse(command(name, ['/opt/puppetlabs/bin/facter', '--json', 'networking', 'empeira']))
    expect(facts.fetch('networking')).to include('hostname' => "#{provider}-node", 'domain' => 'lab.example.test',
                                                 'fqdn' => name)
    expect(facts.fetch('empeira')).to eq('provider' => provider, 'hierarchy' => 'empeira')
    expect(command(name, ['/opt/puppetlabs/bin/puppet', 'config', 'print', 'certname'])).to eq(name)
    %w[udp tcp].each do |protocol|
      reply = command(name, [Empeira::Node::Certificates::RUBY, '-e', DNSRedirectWire::CLIENT,
                             protocol, '198.18.0.53', 'server.empeira.internal'])
      expect(JSON.parse(reply)).to include('rcode' => 0)
    end
    expect(command(name, %w[cat /var/lib/hiera-identity])).to eq("#{provider},empeira-only")
  end
end
