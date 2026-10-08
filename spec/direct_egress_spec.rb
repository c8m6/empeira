# frozen_string_literal: true

require_relative '../resources/gateway/configure'

RSpec.describe Empeira::Network::DirectEgress do
  let(:entries) { [{ 'host' => 'example.org', 'ports' => [443] }] }

  it 'resolves every current IPv4 address without replacing DNS with aliases' do
    resolver = described_class::Resolver.new(lookup: ->(_) { %w[192.0.2.11 2001:db8::1 192.0.2.10 192.0.2.11] })
    expect(resolver.resolve(entries).entries).to eq(
      [{ 'host' => 'example.org', 'addresses' => %w[192.0.2.10 192.0.2.11], 'ports' => [443] }]
    )
  end

  it 'replaces previous DNS answers on every reconcile and canonicalizes their order' do
    answers = [%w[192.0.2.11 192.0.2.10], %w[192.0.2.10 192.0.2.11], ['192.0.2.20']]
    resolver = described_class::Resolver.new(lookup: ->(_) { answers.shift })
    first, same, changed = Array.new(3) { resolver.resolve(entries) }
    expect(first.fingerprint).to eq(same.fingerprint)
    expect(changed.fingerprint).not_to eq(first.fingerprint)
    expect(changed.entries.first['addresses']).to eq(['192.0.2.20'])
  end

  it 'does not resolve explicit public or private IP destinations' do
    resolver = described_class::Resolver.new(lookup: ->(_) { raise 'unexpected DNS' })
    config = [{ 'ip' => '203.0.113.10', 'ports' => [443] }, { 'ip' => '10.20.30.40', 'ports' => [22] }]
    described_class.validate!(config)
    expect(resolver.resolve(config).entries.map { |entry| entry['addresses'] })
      .to eq([['10.20.30.40'], ['203.0.113.10']])
  end

  it 'accepts empty, exact hostname and IP rules through the public schema' do
    [[], entries, [{ 'ip' => '192.0.2.10', 'ports' => [8443] }]].each do |value|
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('network' => { 'egress' => value }))
      expect(Empeira::Application.new(project_path: @directory).context.configuration.dig('network',
                                                                                          'egress')).to eq(value)
    end
  end

  it 'rejects missing/both selectors, invalid addresses, wildcards, CIDRs, ports and unknown keys' do
    invalid = [
      { 'host' => 'example.org', 'ip' => '192.0.2.10', 'ports' => [443] }, { 'ports' => [443] },
      { 'host' => '*.example.org', 'ports' => [443] }, { 'host' => '192.0.2.10', 'ports' => [443] },
      { 'ip' => '999.1.1.1', 'ports' => [443] }, { 'ip' => 'foo', 'ports' => [443] },
      { 'ip' => '192.0.2.0/24', 'ports' => [443] }, { 'host' => 'example.org', 'ports' => [] },
      { 'host' => 'example.org', 'ports' => [0] }, { 'host' => 'example.org', 'ports' => [65_536] },
      { 'host' => 'example.org', 'ports' => [443], 'protocol' => 'tcp' }
    ]
    invalid.each do |entry|
      expect { described_class.validate!([entry]) }.to raise_error(Empeira::ConfigurationError, /network.egress\[0\]/)
    end
  end

  it 'rejects explicit IPv6 clearly and fails closed on AAAA-only or failed lookups' do
    expect { described_class.validate!([{ 'ip' => '2001:db8::10', 'ports' => [443] }]) }
      .to raise_error(Empeira::ConfigurationError, /IPv6 is not supported/)
    resolver = described_class::Resolver.new(lookup: ->(_) { ['2001:db8::1'] })
    expect { resolver.resolve(entries) }.to raise_error(Empeira::Error, /supported IPv4/)
    resolver = described_class::Resolver.new(lookup: ->(_) { raise SocketError })
    expect { resolver.resolve(entries) }.to raise_error(Empeira::Error, /could not be resolved/)
  end
end

RSpec.describe EmpeiraGateway do
  let(:plan) do
    { 'version' => 1, 'subnet' => '10.200.30.0/24', 'gateway' => '10.200.30.2', 'dns' => '10.200.30.3',
      'resolvers' => ['10.20.30.1'], 'proxies' => %w[10.200.30.4 10.200.30.5], 'blocked' => ['10.200.30.32'],
      'entries' => [{ 'addresses' => %w[192.0.2.10 192.0.2.11], 'ports' => [443] }] }
  end

  it 'uses one default-drop routed policy without DNAT or alias allocation' do
    rules = described_class.rules(plan, internal: 'eth0', external: 'eth1')
    expect(rules).to include(':FORWARD DROP', ':INPUT DROP', ':OUTPUT DROP',
                             '-d 192.0.2.10/32 -p tcp --dport 443 -j ACCEPT',
                             '-d 192.0.2.11/32 -p tcp --dport 443 -j ACCEPT',
                             '-s 10.200.30.0/24 -o eth1 -j MASQUERADE')
    expect(rules).not_to include('DNAT', '-d 192.0.2.10/32 -p tcp --dport 80', '-o eth1 -j ACCEPT')
    expect(rules.index('-j BOOTSTRAP')).to be < rules.index('-d 192.0.2.10/32')
    expect(rules).to include('-A BOOTSTRAP -s 10.200.30.32/32 -j DROP')
  end

  it 'allows CoreDNS upstream TCP/UDP and proxy HTTP/HTTPS by source without granting those exceptions to nodes' do
    rules = described_class.rules(plan, internal: 'eth0', external: 'eth1')
    expect(rules).to include('-s 10.200.30.3/32 -d 10.20.30.1/32 -p udp --dport 53',
                             '-s 10.200.30.3/32 -d 10.20.30.1/32 -p tcp --dport 53',
                             '-s 10.200.30.4/32 -p tcp -m multiport --dports 80,443')
    expect(rules).not_to include('-s 10.200.30.32/32 -p tcp')
  end

  it 'does not let established outbound connections bypass removed rules' do
    rules = described_class.rules(plan.merge('entries' => []), internal: 'eth0', external: 'eth1')
    expect(rules.lines.grep(/ESTABLISHED/)).to all(include('--ctorigsrc'))
    expect(rules).not_to include('192.0.2.10', '192.0.2.11')
  end

  it 'locks down before parsing a broken replacement plan' do
    path = File.join(@directory, 'gateway.json')
    File.write(path, 'invalid')
    expect(described_class).to receive(:restore).with(described_class.lockdown).ordered
    expect { described_class.apply(path) }.to raise_error(JSON::ParserError)
  end

  it 'rejects invalid generated plans before allowing traffic' do
    expect { described_class.validate(plan) }.not_to raise_error
    expect { described_class.validate(plan.merge('gateway' => '192.0.2.1')) }.to raise_error(/gateway address/)
    expect { described_class.validate(plan.merge('resolvers' => ['2001:db8::1'])) }.to raise_error(/IPv4/)
  end
end
