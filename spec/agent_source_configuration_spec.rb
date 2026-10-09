# frozen_string_literal: true

RSpec.describe 'Agent source configuration' do
  def configuration(agent = {})
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('agent' => agent))
    Empeira::Application.new(project_path: @directory).context.configuration
  end

  def source(config, os: 'ubuntu', release: '24.04', architecture: 'amd64')
    Empeira::Agent::Target.new(os: os, release: release,
                               architecture: architecture).source(config.dig('agent',
                                                                             'install'))
  end

  it 'enables the cache by default and permits explicit disabling' do
    expect(configuration.dig('agent', 'cache', 'enabled')).to be(true)
    expect(configuration('cache' => { 'enabled' => false }).dig('agent', 'cache', 'enabled')).to be(false)
  end

  it 'lets a project APT default supersede built-in release sources and deep-merges OS overrides' do
    config = configuration('install' => { 'apt' => { 'default' => { 'url' => 'https://packages.example.org/apt' },
                                                     'ubuntu24.04' => { 'suite' => 'noble-special' } } })
    expect(source(config)).to eq('url' => 'https://packages.example.org/apt', 'suite' => 'noble-special',
                                 'component' => 'main')
    expect(source(config, release: '22.04')).to include('suite' => 'jammy')
    expect(config.dig('agent', 'install', 'repositories')).not_to have_key('ubuntu24.04')
    expect(config.dig('agent', 'install', 'repositories')).to have_key('el9')
  end

  %w[rocky almalinux oraclelinux].each do |os|
    %w[amd64 arm64].each do |architecture|
      it "resolves generic DNF parameters for #{os} #{architecture}" do
        config = configuration('install' => { 'dnf' => { 'default' => {
                                 'url' => 'https://packages.example.org/yum/$releasever/$basearch'
                               } } })
        expected = architecture == 'amd64' ? 'x86_64' : 'aarch64'
        expect(source(config, os: os, release: '8', architecture: architecture))
          .to eq('url' => "https://packages.example.org/yum/8/#{expected}")
      end
    end
  end

  it 'supports a complete OS override without losing unrelated defaults' do
    config = configuration('install' => { 'apt' => {
                             'default' => { 'url' => 'https://packages.example.org/$suite',
                                            'verify_signatures' => false },
                             'ubuntu24.04' => { 'url' => 'https://other.example.org/apt', 'component' => 'agent', 'verify_signatures' => true }
                           } })
    expect(source(config)).to include('url' => 'https://other.example.org/apt', 'verify_signatures' => true)
    expect(source(config, release: '22.04')).to include('url' => 'https://packages.example.org/jammy')
  end

  it 'clears inherited checksum pins when an OS override selects a different package or key URL' do
    defaults = { 'url' => 'https://packages.example.org/apt', 'sha256' => 'a' * 64,
                 'key' => { 'url' => 'https://packages.example.org/key.gpg', 'sha256' => 'b' * 64 } }
    override = { 'url' => 'https://other.example.org/apt',
                 'key' => { 'url' => 'https://other.example.org/key.gpg' } }
    config = configuration('install' => { 'apt' => { 'default' => defaults, 'ubuntu24.04' => override } })
    expect(source(config)).not_to have_key('sha256')
    expect(source(config).fetch('key')).to eq('url' => 'https://other.example.org/key.gpg')
    expect(source(config, release: '22.04')).to include('sha256' => 'a' * 64)
  end

  it 'accepts optional checksums, signing keys, suffixes and explicit native versions' do
    packages = { 'ubuntu24.04' => { 'amd64' => { 'url' => 'https://packages.example.org/agent.deb' } } }
    config = configuration('version' => '1:8.20.0-1noble',
                           'install' => { 'method' => 'package', 'packages' => packages })
    expect(source(config)).to eq('url' => 'https://packages.example.org/agent.deb')
  end

  [
    { 'cache' => { 'enabled' => 'yes' } }, { 'cache' => { 'directory' => '/tmp' } },
    { 'install' => { 'apt' => { 'default' => { 'url' => 'https://packages.example.org/$HOME' } } } },
    { 'install' => { 'dnf' => { 'default' => { 'url' => 'https://user:secret@packages.example.org/yum' } } } },
    { 'install' => { 'dnf' => { 'el9' => { 'url' => 'https://packages.example.org/yum', 'password' => 'secret' } } } },
    { 'install' => { 'apt' => { 'ubuntu24.04' => { 'suite' => 'special' } } } }
  ].each_with_index do |fragment, index|
    it "rejects invalid agent fragments with a full path (#{index})" do
      expect { configuration(fragment) }.to raise_error(Empeira::ConfigurationError, /agent\./)
    end
  end
end
