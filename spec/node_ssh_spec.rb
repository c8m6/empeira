# frozen_string_literal: true

RSpec.describe Empeira::Node::SSHClient do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:credentials) do
    Empeira::Node::SSHCredentials.new(context: app.context, runner: Empeira::Execution::Runner.new,
                                      provider: 'container', hostname: 'ssh-node')
  end
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:client) { described_class.new(runner: runner, credentials: credentials, user: 'root') }
  let(:record) { { 'hostname' => 'ssh-node', 'ssh_host' => '127.0.0.1', 'ssh_port' => 32_123 } }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }

  before do
    allow(app.context.locations).to receive(:workspace).and_return(Pathname(@directory).join('state with spaces'))
    credentials.prepare
  end

  it 'uses private per-node credentials and isolated host keys without password authentication' do
    options = client.options(record)
    expect(options).to include(credentials.key_path.to_s, '32123', 'BatchMode=yes',
                               'PasswordAuthentication=no', 'StrictHostKeyChecking=accept-new')
    expect(options).to include("UserKnownHostsFile=\"#{credentials.known_hosts}\"", 'ForwardAgent=no')
    expect(credentials.key_path.stat.mode & 0o777).to eq(0o600)
    expect(credentials.directory.stat.mode & 0o777).to eq(0o700)
    expect(record.to_s).not_to include(credentials.key_path.read)
  end

  it 'quotes known-host paths and escapes OpenSSH tokens for arbitrary supported home directories' do
    path = Pathname(@directory).join('home %name "quoted"/known_hosts')
    allow(credentials).to receive(:known_hosts).and_return(path)
    runner = Empeira::Execution::Runner.new
    result = runner.run('ssh', arguments: ['-G', *client.options(record), client.destination])
    expect(result).to be_success
    expect(result.stdout).to include("userknownhostsfile #{path}\n")
  end

  it 'runs a real SSH client with a TTY through the central stream runner and returns its actual status' do
    failure = success.with(exit_status: 7)
    expect(runner).to receive(:run).with('ssh', arguments: [*client.options(record), 'root@127.0.0.1', 'true'],
                                                timeout: 15).and_return(success)
    expect(runner).to receive(:stream).with('ssh',
                                            arguments: ['-tt', *client.options(record),
                                                        'root@127.0.0.1']).and_return(failure)
    expect(client.session(record).exit_status).to eq(7)
  end

  it 'rejects unavailable SSH, unsafe endpoints and missing credentials before an interactive session' do
    expect(runner).to receive(:run).and_return(success.with(exit_status: 255))
    expect(runner).not_to receive(:stream)
    expect { client.session(record) }.to raise_error(Empeira::Error, /SSH daemon or managed authentication/)
    expect { client.options(record.merge('ssh_host' => '0.0.0.0')) }.to raise_error(Empeira::Error, /endpoint/)
    credentials.cleanup
    expect { client.options(record) }.to raise_error(Empeira::Error, /key material/)
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
