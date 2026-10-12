# frozen_string_literal: true

require_relative '../resources/gateway/configure'

RSpec.describe 'DNS redirect contracts' do
  let(:rules) do
    %w[udp tcp].map do |protocol|
      { 'from' => { 'ip' => '198.18.0.53', 'port' => 53, 'protocol' => protocol },
        'to' => { 'service' => 'coredns', 'port' => 53 } }
    end
  end

  it 'allows distinct UDP/TCP tuples and treats omitted TCP as an explicit TCP duplicate' do
    expect { Empeira::Configuration::NetworkRedirects.validate!(rules, 'network.redirects') }.not_to raise_error
    duplicate = rules.last.merge('from' => rules.last.fetch('from').except('protocol'))
    expect { Empeira::Configuration::NetworkRedirects.validate!([rules.last, duplicate], 'network.redirects') }
      .to raise_error(Empeira::ConfigurationError, /duplicate source/)
  end

  it 'preserves defaults through deep merge while replacing the entire redirect array' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('network' => { 'redirects' => rules }))
    effective = Empeira::Configuration::Loader.new(project_path: @directory).load
    expect(effective.dig('network', 'redirects')).to eq(rules)
    expect(effective.dig('network', 'egress')).to eq([])
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('network' => { 'redirects' => [rules.last] }))
    expect(Empeira::Configuration::Loader.new(project_path: @directory).load.dig('network', 'redirects'))
      .to eq([rules.last])
  end

  it 'limits UDP to built-in DNS and rejects invalid protocol selectors' do
    %w[UDP icmp sctp any].each do |protocol|
      invalid = rules.first.merge('from' => rules.first.fetch('from').merge('protocol' => protocol))
      expect { Empeira::Configuration::NetworkRedirects.validate!([invalid], 'network.redirects') }
        .to raise_error(Empeira::ConfigurationError, /from.protocol/)
    end
    invalid = [rules.first.merge('to' => { 'service' => 'server', 'port' => 53 }),
               rules.first.merge('to' => { 'service' => 'coredns', 'port' => 54 }),
               rules.first.merge('from' => rules.first.fetch('from').merge('port' => 54))]
    invalid.each do |entry|
      expect { Empeira::Configuration::NetworkRedirects.validate!([entry], 'network.redirects') }
        .to raise_error(Empeira::ConfigurationError, /UDP redirects/)
    end
  end

  it 'resolves the alias exclusively to currently owned CoreDNS addresses and keeps failed targets blocked' do
    app = Empeira::Application.new(project_path: @directory)
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    Empeira::Network::Redirects.validate!(rules, definitions: plan.definitions, subnet: '10.200.30.0/24')
    dns = plan.definitions.fetch('dns')
    resource = { 'id' => 'owned', 'name' => dns.name, 'labels' => dns.labels, 'state' => 'running',
                 'networks' => { plan.network => { 'IPAddress' => '10.200.30.3' } } }
    resolver = Empeira::Network::Redirects.new(entries: rules, network: plan.network, subnet: '10.200.30.0/24')
    expect(resolver.resolve(definitions: plan.definitions, resources: { 'dns' => resource }).map do |r|
      r.dig('to', 'ip')
    end)
      .to eq(%w[10.200.30.3 10.200.30.3])
    resource.fetch('networks').fetch(plan.network)['IPAddress'] = '10.200.30.7'
    expect(resolver.resolve(definitions: plan.definitions, resources: { 'dns' => resource }).first.dig('to', 'ip'))
      .to eq('10.200.30.7')
    resource['state'] = 'stopped'
    expect(resolver.resolve(definitions: plan.definitions, resources: { 'dns' => resource }).map { |r| r['to'] })
      .to eq([nil, nil])
    expect { resolver.resolve(definitions: plan.definitions, resources: { 'dns' => resource.merge('labels' => {}) }) }
      .to raise_error(Empeira::Providers::OwnershipError)
  end

  it 'rejects benchmark overlaps with host/VPN/runtime routes and preserves legacy TCP destinations' do
    %w[198.18.0.53/32 198.18.0.0/24 198.18.0.0/15 128.0.0.0/1].each do |route|
      expect { Empeira::Network::Redirects.validate_routes!(rules, routes: [route]) }
        .to raise_error(Empeira::ConfigurationError, %r{host/VPN/runtime route})
    end
    expect { Empeira::Network::Redirects.validate_routes!(rules, routes: ['192.0.2.0/24']) }.not_to raise_error
    legacy = rules.last.merge('from' => { 'ip' => '192.0.2.8', 'port' => 8080 })
    expect { Empeira::Network::Redirects.validate_routes!([legacy], routes: ['192.0.2.0/24']) }.not_to raise_error
  end

  it 'never broadens direct egress to benchmark addresses, including hostname resolutions' do
    expect { Empeira::Network::DirectEgress.validate!([{ 'ip' => '198.18.0.53', 'ports' => [53] }]) }
      .to raise_error(Empeira::ConfigurationError, /reserved for validated redirect sources/)
    resolver = Empeira::Network::DirectEgress::Resolver.new(lookup: ->(_) { ['198.18.0.53'] })
    expect { resolver.resolve([{ 'host' => 'dns.example.test', 'ports' => [53] }]) }
      .to raise_error(Empeira::Error, /reserved for redirect sources/)
  end

  it 'uses protocol-scoped DNAT/SNAT and fail-closed original-tuple drops without external UDP grants' do
    redirects = rules.map { |r| { 'from' => r['from'], 'to' => { 'ip' => '10.200.30.3', 'port' => 53 } } }
    plan = { 'version' => 1, 'subnet' => '10.200.30.0/24', 'gateway' => '10.200.30.2', 'dns' => '10.200.30.3',
             'resolvers' => [], 'proxies' => [], 'blocked' => [], 'entries' => [], 'redirects' => redirects }
    expect { EmpeiraGateway.validate(plan) }.not_to raise_error
    generated = EmpeiraGateway.rules(plan, internal: 'eth0', external: 'eth1')
    %w[tcp udp].each do |protocol|
      expect(generated).to include("-p #{protocol} --dport 53 -j DNAT --to-destination 10.200.30.3:53",
                                   "--ctproto #{protocol} --ctstate DNAT --ctdir ORIGINAL " \
                                   '-j SNAT --to-source 10.200.30.2',
                                   "--ctorigdst 198.18.0.53 --ctorigdstport 53 --ctproto #{protocol} -j DROP")
    end
    expect(generated).not_to match(/-o eth1.*-p udp.*-j ACCEPT/)
    missing = plan.merge('redirects' => redirects.map { |r| r.merge('to' => nil) })
    expect(EmpeiraGateway.rules(missing, internal: 'eth0', external: 'eth1')).not_to include('DNAT --to-destination')
    mixed = redirects.last.merge('from' => redirects.last['from'].except('protocol'))
    expect { EmpeiraGateway.validate(plan.merge('redirects' => [redirects.last, mixed])) }.to raise_error(/Duplicate/)
  end
end
