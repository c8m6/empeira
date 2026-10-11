# frozen_string_literal: true

RSpec.describe Empeira::Node::SSHClient do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:credentials) do
    Empeira::Node::SSHCredentials.new(context: app.context, runner: Empeira::Execution::Runner.new,
                                      provider: 'container', hostname: 'ssh-node')
  end
  let(:client) { described_class.new(credentials: credentials) }
  let(:record) { { 'hostname' => 'ssh-node', 'ssh_host' => '127.0.0.1', 'ssh_port' => 32_123 } }

  before do
    allow(app.context.locations).to receive(:workspace).and_return(Pathname(@directory).join('state with spaces'))
    credentials.prepare
  end

  it 'keeps system SSH credentials and known hosts private to one owned node' do
    credentials.verify!
    expect(client.known_hosts_option).to eq("UserKnownHostsFile=\"#{credentials.known_hosts}\"")
    expect(credentials.key_path.stat.mode & 0o777).to eq(0o600)
    expect(credentials.directory.stat.mode & 0o777).to eq(0o700)
    expect(record.to_s).not_to include(credentials.key_path.read)
  end

  it 'quotes known-host paths and escapes OpenSSH tokens for arbitrary supported home directories' do
    path = Pathname(@directory).join('home %name "quoted"/known_hosts')
    allow(credentials).to receive(:known_hosts).and_return(path)
    runner = Empeira::Execution::Runner.new
    result = runner.run('ssh',
                        arguments: ['-G', '-F', File::NULL, '-o', client.known_hosts_option, record.fetch('hostname')])
    expect(result).to be_success
    expect(result.stdout).to include("userknownhostsfile #{path}\n")
  end

  it 'quotes byte-connector arguments and escapes OpenSSH percent tokens' do
    proxy = ['adapter', 'arg with spaces', 'percent%name']
    policy = described_class.new(credentials: credentials, proxy_command: proxy)
    expect(policy.proxy_options).to eq(['-o', "ProxyCommand=#{Shellwords.join(proxy).gsub('%', '%%')}"])
  end

  it 'deletes only its managed credentials and stale host keys on destroy' do
    credentials.known_hosts.write('synthetic host key')
    other = Pathname(@directory).join('another-node')
    other.mkdir
    credentials.cleanup
    expect(credentials.directory).not_to exist
    expect(other).to exist
  end
end

RSpec.describe Empeira::Node::SSHEndpoint do
  let(:record) do
    { 'ssh_host' => '127.0.0.1', 'ssh_port' => 32_123, 'ssh_transport' => 'loopback',
      'definition' => { 'ports' => ['127.0.0.1::22/tcp'] } }
  end
  let(:binding) { [{ 'HostIp' => '127.0.0.1', 'HostPort' => '32123' }] }
  let(:resource) do
    { 'state' => 'running', 'ports' => { '22/tcp' => binding }, 'published_ports' => { '22/tcp' => binding } }
  end

  it 'accepts exactly the persisted loopback SSH endpoint and rejects any inconsistent binding' do
    expect(described_class.valid?(resource, record)).to be(true)
    expect(described_class.port(resource)).to eq(32_123)
    expect(described_class.valid?(resource, record.merge('ssh_port' => 32_124))).to be(false)
    expect(described_class.valid?(resource.merge('ports' => { '80/tcp' => binding }), record)).to be(false)
    binding[0]['HostIp'] = '0.0.0.0'
    expect(described_class.valid?(resource, record)).to be(false)
  end
end
