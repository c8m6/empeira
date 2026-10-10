# frozen_string_literal: true

RSpec.describe Empeira::Configuration::SSHPreferences do
  let(:config) do
    { 'user' => 'global', 'identity' => '/global/key',
      'rules' => [{ 'hosts' => ['WEB-*', 'db-*'], 'user' => 'host-user', 'identity' => '/first/key' },
                  { 'hosts' => ['*.EXAMPLE.NET'], 'identity' => '/last/key' },
                  { 'hosts' => ['web-?.example.net'], 'user' => 'last-user' }] }
  end
  let(:preferences) { described_class.new(config) }

  it 'keeps provider defaults available without configuration' do
    expect(described_class.new.resolve(hostname: 'host')).to eq(user: nil, identity: nil, port: nil)
  end

  it 'applies global defaults when no hostname rule matches' do
    expect(preferences.resolve(hostname: 'app.example.org')).to eq(user: 'global', identity: '/global/key', port: nil)
  end

  it 'matches any pattern in a rule, ignoring hostname and pattern case' do
    expect(preferences.resolve(hostname: 'DB-ONE')).to eq(user: 'host-user', identity: '/first/key', port: nil)
  end

  it 'applies every matching rule in order, preserving independently omitted fields' do
    expect(preferences.resolve(hostname: 'Web-A.Example.Net')).to eq(user: 'last-user', identity: '/last/key',
                                                                     port: nil)
    expect(preferences.resolve(hostname: 'web-long.example.net')).to eq(user: 'host-user', identity: '/last/key',
                                                                        port: nil)
    expect(config['user']).to eq('global')
  end

  it 'matches the whole hostname rather than substrings' do
    expect(described_class.new('rules' => [{ 'hosts' => ['web'], 'user' => 'exact' }])
      .resolve(hostname: 'web.example.net')).to eq(user: nil, identity: nil, port: nil)
  end

  [{ user: 'cli-user' }, { identity: '/cli/key' }, { user: 'cli-user', identity: '/cli/key' }].each do |overrides|
    it "resolves CLI #{overrides.keys.join('/')} independently above rules and global defaults" do
      expected = { user: 'last-user', identity: '/last/key', port: nil }.merge(overrides)
      expect(preferences.resolve(hostname: 'web-a.example.net', **overrides)).to eq(expected)
    end
  end

  [
    [[], /ssh must be a mapping/],
    [{ 'password' => 'synthetic-secret' }, /ssh.password/],
    [{ 'user' => nil }, /ssh.user/],
    [{ 'user' => 'two words' }, /ssh.user/],
    [{ 'identity' => 'relative/key' }, /ssh.identity/],
    [{ 'identity' => '~someone/key' }, /ssh.identity/],
    [{ 'identity' => "/key\n" }, /ssh.identity/],
    [{ 'identity' => nil }, /ssh.identity/],
    [{ 'rules' => {} }, /ssh.rules/],
    [{ 'rules' => [{ 'hosts' => ['web-*'] }] }, /ssh.rules.0.*at least one/],
    [{ 'rules' => [{ 'hosts' => [], 'user' => 'root' }] }, /ssh.rules.0.hosts/],
    [{ 'rules' => [{ 'hosts' => 'web-*', 'user' => 'root' }] }, /ssh.rules.0.hosts/],
    [{ 'rules' => [{ 'hosts' => ['[ab]'], 'user' => 'root' }] }, /ssh.rules.0.hosts/],
    [{ 'rules' => [{ 'hosts' => ['web-*'], 'user' => 'root', 'password' => 'synthetic-secret' }] },
     /ssh.rules.0.password/],
    [{ 'rules' => [{ 'hosts' => ['web-*'], 'identity' => 'relative/key' }] }, /ssh.rules.0.identity/]
  ].each do |data, message|
    it "rejects malformed preferences at #{message}" do
      expect { described_class.validate!(data) }.to raise_error(Empeira::ConfigurationError, message) do |error|
        expect(error.message).not_to include('synthetic-secret')
      end
    end
  end

  it 'accepts independent defaults and rules, without touching identity files during configuration load' do
    [{}, { 'user' => 'root' }, { 'identity' => '~/missing/key' }, { 'rules' => [] }, config].each do |data|
      expect { described_class.validate!(data) }.not_to raise_error
    end
  end

  it 'resolves ports independently through global, last matching rule and CLI precedence' do
    config['port'] = 22
    config['rules'][0]['port'] = 2222
    config['rules'] << { 'hosts' => ['*.example.net'], 'port' => 2200 }
    expect(preferences.resolve(hostname: 'web-a.example.net')).to eq(
      user: 'last-user', identity: '/last/key', port: 2200
    )
    expect(preferences.resolve(hostname: 'web-a.example.net', port: 2223)).to eq(
      user: 'last-user', identity: '/last/key', port: 2223
    )
    expect(preferences.resolve(hostname: 'other')).to include(port: 22)
    expect { described_class.validate!('rules' => [{ 'hosts' => ['*'], 'port' => 2222 }]) }.not_to raise_error
  end

  [0, 65_536, '22', nil, true, 22.5].each do |value|
    it "rejects invalid personal port #{value.inspect} with its full path" do
      expect { described_class.validate!('rules' => [{ 'hosts' => ['*'], 'port' => value }]) }
        .to raise_error(Empeira::ConfigurationError, /ssh.rules.0.port/)
    end
  end
end
