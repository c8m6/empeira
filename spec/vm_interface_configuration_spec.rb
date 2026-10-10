# frozen_string_literal: true

RSpec.describe Empeira::Configuration::VMInterfaces do
  let(:devices) { { 'dummy0' => { 'network' => '192.0.2.10/32' } } }
  let(:rules) { [{ 'hosts' => ['web-*.example.test', 'db-*'], 'devices' => devices }] }

  def validate(value)
    described_class.validate!(value)
  end

  it 'loads the empty default and validates fragments through the existing loader' do
    expect(Empeira::Configuration::Loader.new(project_path: @directory).load.dig('vm', 'interfaces')).to eq([])
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('vm' => { 'interfaces' => rules }))
    config = Empeira::Configuration::Loader.new(project_path: @directory).load
    expect(config.dig('vm', 'interfaces')).to eq(rules)
    expect(config.dig('vm', 'disk')).to eq(30)
  end

  it 'loads disk capacity and interface rules together without replacing console defaults' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('vm' => { 'disk' => 32, 'interfaces' => rules }))
    config = Empeira::Configuration::Loader.new(project_path: @directory).load
    expect(config.fetch('vm')).to eq('disk' => 32, 'interfaces' => rules,
                                     'console' => { 'root_password' => 'empeira' })
    expect(described_class.resolve(config.dig('vm', 'interfaces'), 'WEB-A.EXAMPLE.TEST')).to eq(devices)
  end

  it 'matches full hostnames case-insensitively using the proxy glob semantics' do
    rules.first['hosts'] << 'API-?.Example.Test'
    validate(rules)
    %w[WEB-A.Example.Test db-one API-2.EXAMPLE.TEST].each do |hostname|
      expect(described_class.resolve(rules, hostname)).to eq(devices)
    end
    %w[web-a other.example.test x.web-a.example.test].each do |hostname|
      expect(described_class.resolve(rules, hostname)).to eq({})
    end
  end

  it 'merges every matching rule and deduplicates identical definitions' do
    rules << { 'hosts' => ['web-*'],
               'devices' => devices.merge('ens192' => { 'network' => '198.51.100.10/24', 'vlan_id' => 123 }) }
    expect(described_class.resolve(rules, 'web-one.example.test')).to eq(rules.last.fetch('devices'))
  end

  it 'identifies conflicting definitions with hostname, interface and both paths' do
    rules << { 'hosts' => ['*'], 'devices' => { 'dummy0' => { 'network' => '192.0.2.11/32' } } }
    expect { described_class.resolve(rules, 'web-one.example.test') }
      .to raise_error(Empeira::ConfigurationError,
                      /Host web-one.example.test, interface dummy0.*vm.interfaces\[1\].*vm.interfaces\[0\]/)
  end

  [nil, {}, 'invalid'].each do |value|
    it "rejects a non-array rules value #{value.inspect}" do
      expect { validate(value) }.to raise_error(Empeira::ConfigurationError, /vm.interfaces.*array/)
    end
  end

  [{}, { 'hosts' => [] }, { 'hosts' => ['*'], 'devices' => {} },
   { 'hosts' => ['[abc]'], 'devices' => { 'dummy0' => { 'network' => '192.0.2.1/32' } } },
   { 'hosts' => ['*'], 'devices' => {}, 'extra' => true }].each do |rule|
    it "rejects invalid rule shape #{rule.inspect}" do
      expect { validate([rule]) }.to raise_error(Empeira::ConfigurationError, /vm.interfaces\[0\]/)
    end
  end

  %w[lo eth0 peer empeira-vlan abcdefghijklmnop a:b a/b . .. -option].each do |name|
    it "rejects invalid or reserved interface name #{name}" do
      rules.first['devices'] = { name => { 'network' => '192.0.2.10/32' } }
      expect do
        validate(rules)
      end.to raise_error(Empeira::ConfigurationError, /vm.interfaces\[0\].devices.*interface.*hosts:/)
    end
  end

  %w[192.0.2.10 192.0.2.10/33 192.0.2.10/255.255.255.0 2001:db8::1/64 127.0.0.1/32
     0.0.0.1/32 224.0.0.1/32 255.255.255.255/32 169.254.169.254/32 100.64.0.1/32
     192.0.2.0/24 192.0.2.255/24 192.0.2.10/0 192.0.2.999/32 192.000.2.10/32].each do |network|
    it "rejects unsuitable address #{network}" do
      devices['dummy0']['network'] = network
      expect do
        validate(rules)
      end.to raise_error(Empeira::ConfigurationError, /vm.interfaces\[0\].devices.dummy0.*network/)
    end
  end

  [nil, 0, 4095, '123', true].each do |vlan|
    it "rejects noninteger or out-of-range VLAN #{vlan.inspect}" do
      devices['dummy0']['vlan_id'] = vlan
      expect { validate(rules) }.to raise_error(Empeira::ConfigurationError, /vlan_id/)
    end
  end

  it 'accepts both VLAN boundaries, host /24 addresses and /31 endpoints' do
    [1, 4094].each do |vlan|
      devices['dummy0'] = { 'network' => '198.51.100.10/24', 'vlan_id' => vlan }
      expect { validate(rules) }.not_to raise_error
    end
    devices['dummy0'] = { 'network' => '192.0.2.0/31' }
    expect { validate(rules) }.not_to raise_error
  end

  it 'rejects additional device keys and separate prefix/netmask properties' do
    %w[prefix netmask unknown].each do |key|
      devices['dummy0'][key] = 24
      expect { validate(rules) }.to raise_error(Empeira::ConfigurationError, /permits only optional vlan_id/)
      devices['dummy0'].delete(key)
    end
  end

  it 'rejects duplicate addresses, overlapping connected networks and duplicate VLAN IDs after merging' do
    definitions = [
      { 'network' => '192.0.2.10/24' },
      { 'network' => '192.0.2.11/24' },
      { 'network' => '198.51.100.1/32', 'vlan_id' => 123 }
    ]
    devices['dummy0']['vlan_id'] = 123
    definitions.each do |definition|
      second = { 'hosts' => ['*'], 'devices' => { 'ens192' => definition } }
      expect { described_class.resolve(rules + [second], 'db-one') }
        .to raise_error(Empeira::ConfigurationError, /vm.interfaces.*host db-one.*(duplicate|overlapping)/)
    end
  end
end
