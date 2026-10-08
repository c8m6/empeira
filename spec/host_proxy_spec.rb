# frozen_string_literal: true

RSpec.describe Empeira::Network::HostPolicy do
  let(:config) do
    { 'global' => ['forgeapi.puppet.com'], 'rules' => [
      { 'hosts' => ['lab-*'], 'allow' => ['*.github.com'] },
      { 'hosts' => ['*-web-*'], 'allow' => ['github.com', '*.github.com'] },
      { 'hosts' => ['*-db-??.*'], 'allow' => ['database.example'] }
    ] }
  end

  it 'uses complete normalized hostnames and additive deduplicated rules for every provider' do
    policy = described_class.new(config)
    expect(policy.resolve('LAB-web-1-01.example.net')).to eq(
      ['forgeapi.puppet.com', '*.github.com', 'github.com']
    )
    %w[prod-web-blue.example.net abc-web-test].each do |name|
      expect(policy.resolve(name)).to include('github.com')
    end
    expect(policy.resolve('prod-db-01.example')).to include('database.example')
    expect(policy.resolve('prod-db-001.example')).to eq(['forgeapi.puppet.com'])
    expect(described_class.new('global' => [], 'rules' => []).resolve('anything')).to be_empty
  end

  it 'rejects malformed host globs and unsafe destination syntax with complete paths' do
    expect { described_class.validate!([{ 'hosts' => ['*'], 1 => [] }]) }
      .to raise_error(Empeira::ConfigurationError, /proxy.rules.0 requires hosts and allow arrays/)
    ['UPPER-*', '[ab]*', 'host/other', 'a|b', '', "a\nb"].each do |pattern|
      expect { described_class.validate!([{ 'hosts' => [pattern], 'allow' => [] }]) }
        .to raise_error(Empeira::ConfigurationError, /proxy.rules.0.hosts/)
    end
    %w[https://github.com github.com/path 10.0.0.1 github.com:443].each do |domain|
      expect { described_class.validate!([{ 'hosts' => ['*'], 'allow' => [domain] }]) }
        .to raise_error(Empeira::ConfigurationError, /proxy.rules.0.allow/)
    end
  end

  it 'binds container policies to source addresses and VM policies to their leased source addresses' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('proxy' => config))
    app = Empeira::Application.new(project_path: @directory,
                                   locations: Empeira::Platform::Locations.new(
                                     home: File.join(@directory, 'user-home'), environment: {}
                                   ))
    resources = { 'server' => { 'networks' => { 'internal' => { 'IPAddress' => '172.20.0.1' } } },
                  'lab-web-container' => { 'networks' => { 'internal' => { 'IPAddress' => '172.20.0.2' } } },
                  'lab-web-vm' => { 'networks' => { 'internal' => { 'IPAddress' => '172.20.0.3' } } },
                  'legacy-node' => { 'networks' => { 'internal' => { 'IPAddress' => '172.20.0.4' } } } }
    nodes = { 'lab-web-container' => { 'provider' => 'container', 'internet' => true },
              'lab-web-vm' => { 'provider' => 'vm', 'internet' => true },
              'legacy-node' => { 'provider' => 'vm', 'internet' => false } }
    output = Empeira::Network::ProxyBindings.new(context: app.context, resources: resources,
                                                 network: 'internal', nodes: nodes).configuration
    expect(output).to include('src 172.20.0.2', 'src 172.20.0.3', 'src 172.20.0.4')
    expect(output.scan('dstdomain -n forgeapi.puppet.com .github.com github.com').size).to eq(2)
    expect(output).to include('node_2_source')
    files = Empeira::ControlPlane::Files.new(context: app.context)
    files.prepare
    files.proxy_clients(resources, 'internal', nodes: nodes)
    expect(File.readlines(files.path('proxy-clients'), chomp: true))
      .to contain_exactly('127.0.0.1/32', '172.20.0.1', '172.20.0.2', '172.20.0.3', '172.20.0.4')
  end
end
