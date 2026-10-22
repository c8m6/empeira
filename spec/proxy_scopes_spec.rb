# frozen_string_literal: true

require_relative '../resources/gateway/configure'

RSpec.describe 'Independent node and infrastructure access' do
  def application(nodes: false, infrastructure: false, extra: {})
    config = { 'proxy' => {
      'nodes' => { 'enabled' => nodes, 'global' => ['node.example.net'],
                   'rules' => [{ 'hosts' => ['*'], 'allow' => ['node-rule.example.net'] }] },
      'infrastructure' => { 'enabled' => infrastructure, 'allow' => ['infra.example.net'] }
    } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config.merge(extra)))
    Empeira::Application.new(project_path: @directory)
  end

  [false, true].product([false, true]).each do |nodes, infrastructure|
    it "keeps environments and bindings separate with nodes=#{nodes}, infrastructure=#{infrastructure}" do
      app = application(nodes: nodes, infrastructure: infrastructure)
      plan = Empeira::ControlPlane::Plan.new(context: app.context)
      expect(plan.proxy?).to eq(nodes || infrastructure)
      expect(plan.node_proxy_environment.empty?).to eq(!nodes)
      definitions = plan.definitions
      expect(definitions.key?('proxy')).to eq(nodes || infrastructure)
      %w[server postgres puppetdb-backend puppetdb].each do |name|
        environment = definitions.fetch(name).options.fetch('environment')
        %w[http_proxy https_proxy HTTP_PROXY HTTPS_PROXY].each do |variable|
          expect(environment.fetch(variable)).to eq(infrastructure ? 'http://proxy.empeira.internal:3128' : '')
        end
      end
      resources = { 'server' => { 'networks' => { 'internal' => { 'IPAddress' => '192.0.2.10' } } },
                    'node.example.test' => { 'networks' => { 'internal' => { 'IPAddress' => '192.0.2.20' } } } }
      bindings = Empeira::Network::ProxyBindings.new(context: app.context, resources: resources,
                                                     network: 'internal', nodes: { 'node.example.test' => {} })
      expected = []
      expected << '192.0.2.10' if infrastructure
      expected << '192.0.2.20' if nodes
      expect(bindings.addresses).to match_array(expected)
      rules = bindings.configuration
      expect(rules.include?('infra.example.net')).to eq(infrastructure)
      expect(rules.include?('node.example.net')).to eq(nodes)
      expect(rules.include?('node-rule.example.net')).to eq(nodes)
      expect(rules.lines.grep(/server_domains/).join).not_to include('node.example.net', 'node-rule.example.net')
      expect(rules.lines.grep(/node_0_domains/).join).not_to include('infra.example.net')
    end
  end

  it 'does not give bootstrap nodes normal proxy access even when both scopes are enabled' do
    app = application(nodes: true, infrastructure: true)
    resources = { 'node.example.test' => { 'networks' => { 'internal' => { 'IPAddress' => '192.0.2.20' } } } }
    bindings = Empeira::Network::ProxyBindings.new(context: app.context, resources: resources, network: 'internal',
                                                   nodes: { 'node.example.test' => { 'network_phase' => 'bootstrap' } })
    expect(bindings.addresses).to be_empty
    expect(bindings.configuration).not_to include('192.0.2.20')
  end

  it 'clears inherited host and image proxy settings at the managed container boundary' do
    app = application(nodes: true)
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    %w[server postgres puppetdb-backend puppetdb dns gateway proxy].each do |name|
      arguments = Empeira::Runtime::ServiceArguments.new(plan.definitions.fetch(name)).build
      %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY].each do |variable|
        expect(arguments).to include("#{variable}=")
      end
      expect(arguments).not_to include('http_proxy=http://proxy.empeira.internal:3128')
    end
  end

  it 'applies only infrastructure settings to additional services and retains their application environment' do
    extra = { 'containers' => { 'additional' => [{
      'name' => 'helper', 'image' => { 'repository' => 'example/helper', 'tag' => 'test' },
      'environment' => { 'APP_MODE' => 'fixture' }
    }] } }
    app = application(nodes: true, extra: extra)
    environment = Empeira::ControlPlane::Plan.new(context: app.context).definitions.fetch('helper')
                                             .options.fetch('environment')
    expect(environment).to include('APP_MODE' => 'fixture', 'HTTP_PROXY' => '', 'http_proxy' => '')
    app = application(infrastructure: true, extra: extra)
    environment = Empeira::ControlPlane::Plan.new(context: app.context).definitions.fetch('helper')
                                             .options.fetch('environment')
    expect(environment).to include('APP_MODE' => 'fixture', 'HTTP_PROXY' => 'http://proxy.empeira.internal:3128')
  end

  it 'keeps direct bypass lists and server fingerprints independent of node access' do
    extra = { 'network' => { 'egress' => {
      'nodes' => [{ 'host' => 'node-direct.example.net', 'ports' => [443] }],
      'infrastructure' => [{ 'host' => 'infra-direct.example.net', 'ports' => [8443] }]
    } } }
    app = application(nodes: true, infrastructure: true, extra: extra)
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    node_bypass = plan.node_proxy_environment.fetch('NO_PROXY')
    server = plan.definitions.fetch('server')
    server_bypass = server.options.fetch('environment').fetch('NO_PROXY')
    expect(node_bypass).to include('node-direct.example.net')
    expect(node_bypass).not_to include('infra-direct.example.net')
    expect(server_bypass).to include('infra-direct.example.net')
    expect(server_bypass).not_to include('node-direct.example.net')
    changed = application(infrastructure: true, extra: extra)
    expect(Empeira::ControlPlane::Plan.new(context: changed.context).definitions.fetch('server').fingerprint)
      .to eq(server.fingerprint)
    command = Empeira::Node::RuntimeProxy.command(changed.context, ['puppet'])
    expect(command).to include('HTTP_PROXY=')
    expect(command).not_to include('HTTP_PROXY=http://proxy.empeira.internal:3128')
  end

  [{ 'proxy' => { 'enabled' => true } }, { 'proxy' => { 'global' => ['example.net'] } },
   { 'network' => { 'egress' => [] } }].each do |config|
    it "rejects shared settings instead of silently granting infrastructure access: #{config}" do
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
      expect { Empeira::Application.new(project_path: @directory) }
        .to raise_error(Empeira::ConfigurationError, /proxy.nodes|network.egress.nodes/)
    end
  end

  it 'reports invalid infrastructure allowlists and switches at their full configuration paths' do
    schema = Empeira::Configuration::Schema.new
    expect { schema.validate_fragment!('proxy' => { 'infrastructure' => { 'allow' => ['http://invalid.example'] } }) }
      .to raise_error(Empeira::ConfigurationError, /proxy.infrastructure.allow/)
    expect { schema.validate_fragment!('proxy' => { 'infrastructure' => { 'enabled' => 'false' } }) }
      .to raise_error(Empeira::ConfigurationError, /proxy.infrastructure.enabled/)
  end
end

RSpec.describe 'Direct-egress source separation' do
  it 'binds node and infrastructure destinations to disjoint pools in both directions' do
    entries = [{ 'scope' => 'nodes', 'addresses' => ['192.0.2.10'], 'ports' => [443] },
               { 'scope' => 'infrastructure', 'addresses' => ['192.0.2.20'], 'ports' => [8443] }]
    resolved = Empeira::Network::DirectEgress::Resolved.new(entries)
    plan = Empeira::Network::Gateway.plan(state: { 'peer_network' => { 'subnet' => '10.200.30.0/24' } },
                                          resolved: resolved, upstreams: ['192.0.2.53'], routes: {})
    nodes, infrastructure = plan.fetch('entries')
    expect(nodes.fetch('sources')).to eq(%w[10.200.30.32/27 10.200.30.64/26])
    expect(infrastructure.fetch('sources')).to eq(['10.200.30.128/25'])
    rules = EmpeiraGateway.rules(plan, internal: 'eth0', external: 'eth1')
    expect(rules).to include('-s 10.200.30.32/27 -d 192.0.2.10/32',
                             '-s 10.200.30.64/26 -d 192.0.2.10/32',
                             '-s 10.200.30.128/25 -d 192.0.2.20/32')
    expect(rules).not_to include('-s 10.200.30.0/24 -d 192.0.2.10',
                                 '-s 10.200.30.128/25 -d 192.0.2.10')
    expect(rules.lines.grep(/192\.0\.2\.(?:10|20).*ESTABLISHED|ESTABLISHED.*192\.0\.2\.(?:10|20)/))
      .to all(include('--ctorigsrc'))
  end

  it 'rejects missing, external and whole-workspace source ranges' do
    %w[192.0.2.0/24 10.200.30.0/24 2001:db8::/64].each do |source|
      expect { EmpeiraGateway.validate_sources([source], IPAddr.new('10.200.30.0/24')) }
        .to raise_error(/Invalid direct-egress source/)
    end
    expect { EmpeiraGateway.validate_sources([], IPAddr.new('10.200.30.0/24')) }
      .to raise_error(/Invalid direct-egress source/)
  end
end
