# frozen_string_literal: true

require_relative '../resources/gateway/configure'

RSpec.describe Empeira::Configuration::NetworkRedirects do
  let(:rule) do
    { 'from' => { 'ip' => '192.0.2.8', 'port' => 8080 }, 'to' => { 'service' => 'api-compat', 'port' => 8081 } }
  end

  def validate(entries)
    described_class.validate!(entries, 'network.redirects')
  end

  it 'loads empty defaults and replacement arrays through the existing configuration loader' do
    expect(Empeira::Application.new(project_path: @directory).context.configuration.dig('network',
                                                                                        'redirects')).to eq([])
    rules = [rule, rule.merge('from' => { 'ip' => '192.0.2.9', 'port' => 8080 })]
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump(JSON.parse(JSON.generate('network' => { 'redirects' => rules }))))
    expect(Empeira::Application.new(project_path: @directory).context.configuration.dig('network',
                                                                                        'redirects')).to eq(rules)
  end

  it 'allows the same source IP on distinct ports and shared targets with distinct ports' do
    expect do
      validate([rule, { 'from' => { 'ip' => '192.0.2.8', 'port' => 443 },
                        'to' => { 'service' => 'api-compat', 'port' => 8443 } }])
    end.not_to raise_error
    expect { validate([rule, rule.merge('to' => { 'service' => 'server', 'port' => 8140 })]) }
      .to raise_error(Empeira::ConfigurationError, /duplicate source/)
  end

  it 'rejects malformed entries and unknown keys at every level' do
    invalid = [nil, {}, rule.merge('protocol' => 'tcp'), rule.merge('from' => rule['from'].merge('cidr' => 24)),
               rule.merge('to' => rule['to'].merge('ip' => '192.0.2.10'))]
    invalid.each do |entry|
      expect { validate([entry]) }.to raise_error(Empeira::ConfigurationError, /network.redirects\[0\]/)
    end
    expect { validate({}) }.to raise_error(Empeira::ConfigurationError, /must be an array/)
  end

  it 'rejects noncanonical, nonroutable, wildcard, IPv6 and CIDR source addresses' do
    %w[999.1.1.1 192.0.2.08 192.0.2.0/24 ::1 127.0.0.1 0.0.0.0 169.254.1.2 224.0.0.1 255.255.255.255 *].each do |ip|
      expect { validate([rule.merge('from' => { 'ip' => ip, 'port' => 8080 })]) }
        .to raise_error(Empeira::ConfigurationError, /network.redirects\[0\].from.ip/)
    end
  end

  it 'rejects invalid ports and hostnames in place of service names' do
    [0, 65_536, '8080', 80.5, nil, '80-90'].each do |port|
      %w[from to].each do |key|
        expect { validate([rule.merge(key => rule[key].merge('port' => port))]) }
          .to raise_error(Empeira::ConfigurationError, /#{key}.port/)
      end
    end
    %w[api-compat.empeira.internal node.example.test 192.0.2.10 http://server Server].each do |name|
      expect { validate([rule.merge('to' => { 'service' => name, 'port' => 8080 })]) }
        .to raise_error(Empeira::ConfigurationError, /to.service/)
    end
  end
end

RSpec.describe Empeira::Network::Redirects do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
  let(:rule) do
    { 'from' => { 'ip' => '192.0.2.8', 'port' => 8080 }, 'to' => { 'service' => 'server', 'port' => 8140 } }
  end
  let(:definition) { plan.definitions.fetch('server') }
  let(:resource) do
    { 'id' => 'owned', 'name' => definition.name, 'labels' => definition.labels, 'state' => 'running',
      'networks' => { plan.network => { 'IPAddress' => '10.200.30.128' } } }
  end

  def resolve(resources)
    described_class.new(entries: [rule], network: plan.network, subnet: '10.200.30.0/24')
                   .resolve(definitions: plan.definitions, resources: resources)
  end

  it 'resolves current observed addresses and leaves unavailable or stale definitions blocked' do
    expect(resolve('server' => resource).first['to']).to eq('ip' => '10.200.30.128', 'port' => 8140)
    resource['networks'][plan.network]['IPAddress'] = '10.200.30.129'
    expect(resolve('server' => resource).first['to']['ip']).to eq('10.200.30.129')
    [nil, resource.merge('state' => 'stopped'),
     resource.merge('labels' => definition.ownership_labels)].each do |missing|
      expect(resolve('server' => missing)).to eq([{ 'from' => rule['from'], 'to' => nil }])
    end
  end

  it 'refuses foreign ownership and addresses outside the owned workspace network' do
    expect { resolve('server' => resource.merge('labels' => {})) }.to raise_error(Empeira::Providers::OwnershipError)
    resource['networks'][plan.network]['IPAddress'] = '192.0.2.99'
    expect { resolve('server' => resource) }.to raise_error(Empeira::Providers::OwnershipError)
  end

  it 'rejects unknown, disabled, node and externally attached infrastructure targets' do
    %w[unknown container-node bootstrap-proxy gateway browser-ui proxy].each do |service|
      entry = rule.merge('to' => { 'service' => service, 'port' => 8080 })
      expect { described_class.validate!([entry], definitions: plan.definitions) }
        .to raise_error(Empeira::ConfigurationError, /to.service/)
    end
  end

  it 'rejects all workspace source addresses including gateway, DNS, leases and reserved addresses' do
    %w[10.200.30.0 10.200.30.1 10.200.30.2 10.200.30.3 10.200.30.32 10.200.30.128 10.200.30.255].each do |ip|
      expect do
        described_class.validate!([rule.merge('from' => { 'ip' => ip, 'port' => 8080 })],
                                  definitions: plan.definitions, subnet: '10.200.30.0/24')
      end.to raise_error(Empeira::ConfigurationError, /collides with the workspace subnet/)
    end
  end
end

RSpec.describe EmpeiraGateway do
  let(:redirect) do
    { 'from' => { 'ip' => '192.0.2.8', 'port' => 8080 }, 'to' => { 'ip' => '10.200.30.128', 'port' => 8081 } }
  end
  let(:plan) do
    { 'version' => 1, 'subnet' => '10.200.30.0/24', 'gateway' => '10.200.30.2', 'dns' => '10.200.30.3',
      'resolvers' => [], 'proxies' => [], 'blocked' => ['10.200.30.32'],
      'entries' => [{ 'addresses' => ['192.0.2.8'], 'ports' => [8080] }], 'redirects' => [redirect] }
  end

  def rules(value = plan)
    described_class.rules(value, internal: 'eth0', external: 'eth1')
  end

  it 'routes only exact TCP pairs with DNAT and a gateway SNAT return path' do
    expect(rules).to include('-d 192.0.2.8/32 -p tcp --dport 8080 -j DNAT --to-destination 10.200.30.128:8081',
                             '--ctstate DNAT --ctdir ORIGINAL -j SNAT --to-source 10.200.30.2',
                             '-s 10.200.30.128/32 -d 10.200.30.0/24 -p tcp --sport 8081',
                             '--ctstate ESTABLISHED --ctdir REPLY -j ACCEPT')
    expect(rules).not_to include('-p udp', '-o eth1 -j ACCEPT')
    expect(rules.index('-j BOOTSTRAP')).to be < rules.index('--ctstate DNAT --ctdir ORIGINAL -j ACCEPT')
  end

  it 'blocks original destinations before ordinary egress grants even without a live target' do
    value = rules(plan.merge('redirects' => [redirect.merge('to' => nil)]))
    expect(value).not_to include('DNAT --to-destination')
    expect(value.index('--ctorigdst 192.0.2.8 --ctorigdstport 8080 -j DROP'))
      .to be < value.index('-d 192.0.2.8/32 -p tcp --dport 8080 -j ACCEPT')
  end

  it 'rejects external targets, internal sources, duplicates, invalid keys and ports in generated plans' do
    bad = [redirect.merge('to' => { 'ip' => '192.0.2.9', 'port' => 8080 }),
           redirect.merge('from' => { 'ip' => '10.200.30.3', 'port' => 8080 }),
           redirect.merge('to' => { 'ip' => '10.200.30.128', 'port' => 0 }), redirect.merge('udp' => true)]
    bad.each do |entry|
      expect do
        described_class.validate(plan.merge('redirects' => [entry]))
      end.to raise_error(RuntimeError)
    end
    expect { described_class.validate(plan.merge('redirects' => [redirect, redirect])) }.to raise_error(/Duplicate/)
  end

  # rubocop:disable-next Metrics/AbcSize -- Bind a generated plan and installed rules to the real helper apply boundary.
  def apply(replacement, installed: plan)
    path = File.join(@directory, 'gateway.json')
    File.write(path, JSON.generate(replacement))
    allow(described_class).to receive(:interfaces).and_return(%w[eth0 eth1])
    allow(described_class).to receive(:command).with('iptables-save').and_return(rules(installed))
    described_class.apply(path)
  end

  it 'installs replacement NAT and flushes only gateway namespace connections while forwarding is blocked' do
    removed = plan.merge('redirects' => [])
    expect(described_class).to receive(:restore).with(described_class.lockdown).ordered
    expect(described_class).to receive(:restore).with(a_string_starting_with('*nat')).ordered
    expect(described_class).to receive(:command).with('conntrack', '--flush').ordered
    expect(described_class).to receive(:restore).with(rules(removed)).ordered
    apply(removed)
  end

  it 'preserves connections on unchanged mappings' do
    allow(described_class).to receive(:restore)
    expect(described_class).not_to receive(:command).with('conntrack', '--flush')
    apply(plan)
  end

  it 'flushes stale connections on addition, source or target changes, and unresolved targets' do
    allow(described_class).to receive(:restore)
    changes = [plan.merge('redirects' => []), plan.merge('redirects' => [redirect.merge('to' => nil)]),
               plan.merge('redirects' => [redirect.merge('to' => redirect['to'].merge('port' => 8082))]),
               plan.merge('redirects' => [redirect.merge('from' => redirect['from'].merge('ip' => '192.0.2.9'))])]
    expect(described_class).to receive(:command).with('conntrack', '--flush').exactly(changes.size).times
    changes.each { |installed| apply(plan, installed: installed) }
  end

  it 'keeps forwarding locked if connection invalidation fails' do
    allow(described_class).to receive(:restore).with(described_class.lockdown)
    allow(described_class).to receive(:restore).with(a_string_starting_with('*nat'))
    allow(described_class).to receive(:command).with('conntrack', '--flush').and_raise('Conntrack failure')
    expect(described_class).not_to receive(:restore).with(rules(plan.merge('redirects' => [])))
    expect { apply(plan.merge('redirects' => [])) }.to raise_error(/Conntrack failure/)
  end

  it 'reports translated target drift through the existing status check' do
    path = File.join(@directory, 'gateway.json')
    File.write(path, JSON.generate(plan))
    allow(described_class).to receive(:interfaces).and_return(%w[eth0 eth1])
    allow(File).to receive(:read).with('/proc/sys/net/ipv4/ip_forward').and_return('1')
    allow(described_class).to receive(:command).with('iptables-save').and_return(rules)
    expect { described_class.check(path) }.not_to raise_error
    changed = rules.sub('--to-destination 10.200.30.128:8081', '--to-destination 10.200.30.129:8081')
    allow(described_class).to receive(:command).with('iptables-save').and_return(changed)
    expect { described_class.check(path) }.to raise_error(/Gateway firewall drift/)
  end
end
