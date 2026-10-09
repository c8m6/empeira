# frozen_string_literal: true

RSpec.describe Empeira::VM::BootstrapRequirements do
  def requirements(fragment = {}, os: 'ubuntu', version: '24.04', architecture: 'amd64', **options)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(fragment))
    context = Empeira::Application.new(project_path: @directory).context
    described_class.new(context: context, os: os, version: version, architecture: architecture, **options)
  end

  it 'selects the OpenVox APT release and reviewed Ubuntu mirrors by default' do
    plan = requirements
    expect(plan).to be_required
    defaults = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
    expect(plan.agent.fetch('package')).to eq(defaults.dig('agent', 'package'))
    source = defaults.dig('agent', 'install', 'repositories', 'ubuntu24.04')
    expect(plan.repository).to eq(source)
    expect(plan.destinations).to contain_exactly('archive.ubuntu.com', 'security.ubuntu.com')
  end

  it 'selects the OpenVox RPM release and reviewed Rocky mirror' do
    plan = requirements({}, os: 'rocky', version: '9')
    source = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
                                           .dig('agent', 'install', 'repositories', 'el9')
    expect(plan.repository).to eq(source)
    expect(plan.destinations).to contain_exactly('dl.rockylinux.org')
    expect(plan.rpm_options).to include('--setopt=baseos.baseurl=https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/')
  end

  it 'deep-merges a partial override of a reviewed release source' do
    fragment = { 'agent' => { 'install' => { 'repositories' => { 'ubuntu24.04' => { 'sha256' => 'a' * 64 } } } } }
    plan = requirements(fragment)
    expected_url = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
                                                 .dig('agent', 'install', 'repositories', 'ubuntu24.04', 'url')
    expect(plan.repository).to include('sha256' => 'a' * 64, 'url' => expected_url)
  end

  it 'selects a signed custom APT source independently of the server image' do
    source = { 'url' => 'https://packages.example.net/agent', 'suite' => 'noble', 'component' => 'main',
               'suffix' => '-1noble',
               'key' => { 'url' => 'https://keys.example.net/agent.gpg', 'sha256' => 'a' * 64 } }
    plan = requirements({ 'agent' => { 'package' => 'puppet-agent', 'version' => '8.20.0',
                                       'install' => { 'apt' => { 'ubuntu24.04' => source } } } })
    expect(plan.agent.fetch('package')).to eq('puppet-agent')
    expect(plan.repository).to eq(source)
    expect(plan.destinations).to contain_exactly('archive.ubuntu.com', 'security.ubuntu.com')
  end

  it 'selects a signed custom DNF source independently of the server image' do
    source = { 'url' => 'https://packages.example.net/agents/el/9/$basearch', 'suffix' => '-2.el9',
               'key' => { 'url' => 'https://keys.example.net/agents.gpg', 'sha256' => 'a' * 64 } }
    plan = requirements({ 'agent' => { 'package' => 'puppet-agent',
                                       'install' => { 'dnf' => { 'el9' => source } } } },
                        os: 'almalinux', version: '9')
    expect(plan.repository).to eq(source.merge('url' => source.fetch('url').sub('$basearch', 'x86_64')))
    expect(plan.destinations).to contain_exactly('repo.almalinux.org')
  end

  it 'selects a direct package by distribution and architecture' do
    package = { 'url' => 'https://packages.example.net/agent.deb', 'sha256' => 'a' * 64 }
    plan = requirements({ 'agent' => { 'install' => { 'method' => 'package',
                                                      'packages' => { 'ubuntu24.04' => { 'arm64' => package } } } } },
                        architecture: 'arm64')
    expect(plan.repository).to eq(package)
    expect(plan.destinations).to contain_exactly('ports.ubuntu.com')
  end

  it 'plans agent installation without validating download credentials' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    expect(requirements).to be_required
  end

  it 'does not need agent egress when the guest declares a preinstalled agent' do
    guests = { 'ubuntu' => { '24.04' => { 'agent_preinstalled' => true } } }
    plan = requirements({ 'bootstrap' => { 'guests' => guests } })
    expect(plan).not_to be_required
    expect(plan.destinations).to be_empty
  end

  it 'retains only distribution egress for package-only bootstrap' do
    plan = requirements({}, agent_required: false, distribution_required: true)
    expect(plan).not_to be_required
    expect(plan.destinations).to contain_exactly('archive.ubuntu.com', 'security.ubuntu.com')
  end

  it 'rejects secrets in agent source configuration' do
    fragment = { 'agent' => { 'install' => { 'dnf' => { 'el9' => { 'password' => 'synthetic-secret' } } } } }
    expect { requirements(fragment) }.to raise_error(Empeira::ConfigurationError, /agent.install.dnf.el9/)
  end
end
