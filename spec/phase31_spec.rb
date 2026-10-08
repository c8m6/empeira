# frozen_string_literal: true

require 'empeira/cli/progress'
require 'stringio'

RSpec.describe 'Phase 3.1 operational contracts' do
  def configuration(fragment)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(fragment))
    Empeira::Application.new(project_path: @directory).context.configuration
  end

  it 'resolves independent image tags and full image overrides without registry access' do
    expect_any_instance_of(Empeira::Runtime::Container).not_to receive(:check_available!)
    config = configuration('images' => { 'server' => { 'tag' => '8.99.0' } })
    resolve = ->(key) { Empeira::Images::Configuration.reference(config['images'][key]) }
    expect(resolve.call('server')).to end_with(':8.99.0')
    config = configuration('images' => { 'server' => { 'reference' => "example.org/server@sha256:#{'a' * 64}" } })
    expect(resolve.call('server')).to eq("example.org/server@sha256:#{'a' * 64}")
    expect(resolve.call('puppetdb')).to end_with("@#{config.dig('images', 'puppetdb', 'digest')}")
  end

  it 'rejects malformed image and DNS fragments at their complete path' do
    expect { configuration('images' => { 'dns' => { 'tag' => 'bad tag' } }) }
      .to raise_error(Empeira::ConfigurationError, /images.dns.tag/)
    expect { configuration('dns' => { 'upstream' => { 'mode' => 'explicit' } }) }
      .to raise_error(Empeira::ConfigurationError, /dns.upstream.servers/)
    expect { configuration('proxy' => { 'dns_servers' => ['1.1.1.1'] }) }
      .to raise_error(Empeira::ConfigurationError, /proxy.dns_servers/)
  end

  it 'discovers corporate resolvers and resolves Linux stub configuration without a public fallback' do
    reader = double('resolver files')
    allow(reader).to receive(:read).with('/etc/resolv.conf').and_return("nameserver 127.0.0.53\n")
    allow(reader).to receive(:read).with('/run/systemd/resolve/resolv.conf').and_return("nameserver 10.1.2.3\n")
    resolver = Empeira::Platform::Resolvers.new(platform: Empeira::Platform::Facts.new(host_os: 'linux'),
                                                runner: instance_double(Empeira::Execution::Runner), reader: reader)
    expect(resolver.resolve('mode' => 'host')).to eq(['10.1.2.3'])
    allow(reader).to receive(:read).with('/run/systemd/resolve/resolv.conf').and_raise(Errno::ENOENT)
    expect { resolver.resolve('mode' => 'host') }.to raise_error(Empeira::Error, /dns.upstream/)
    expect(resolver.resolve('mode' => 'explicit', 'servers' => ['10.9.8.7'])).to eq(['10.9.8.7'])
  end

  it 'uses macOS resolver discovery through the central runner' do
    runner = instance_double(Empeira::Execution::Runner)
    result = Empeira::Execution::Result.new(stdout: "nameserver[0] : 10.2.3.4\n", stderr: '', exit_status: 0,
                                            timed_out: false)
    expect(runner).to receive(:run).with('scutil', arguments: ['--dns'], timeout: 10).and_return(result)
    resolver = Empeira::Platform::Resolvers.new(platform: Empeira::Platform::Facts.new(host_os: 'darwin'),
                                                runner: runner)
    expect(resolver.resolve('mode' => 'host')).to eq(['10.2.3.4'])
  end

  it 'retains macOS VPN split DNS without forwarding the internal Empeira zone' do
    runner = instance_double(Empeira::Execution::Runner)
    output = <<~DNS
      resolver #1
        nameserver[0] : 10.0.0.1
      resolver #2
        domain : corp.example
        nameserver[0] : 10.8.0.1
      resolver #3
        domain : empeira.internal
        nameserver[0] : 10.8.0.2
      resolver #4
        domain : local
        options : mdns
    DNS
    allow(runner).to receive(:run).and_return(Empeira::Execution::Result.new(
                                                stdout: output, stderr: '', exit_status: 0, timed_out: false
                                              ))
    resolver = Empeira::Platform::Resolvers.new(platform: Empeira::Platform::Facts.new(host_os: 'darwin'),
                                                runner: runner)
    expect(resolver.resolve('mode' => 'host')).to eq(['10.0.0.1'])
    expect(resolver.routes).to eq('corp.example' => ['10.8.0.1'])
  end

  it 'validates complete new node and agent definitions without consulting a registry' do
    expect { configuration('images' => { 'nodes' => { 'example' => { '1' => { 'tag' => '1' } } } }) }
      .to raise_error(Empeira::ConfigurationError, /images.nodes.example.1.architectures/)
    expect { configuration('agent' => { 'install' => { 'method' => 'package' } }) }
      .to raise_error(Empeira::ConfigurationError, /agent.install.packages/)
  end

  it 'emits monotonic workflow progress and completes only after successful work' do
    events = []
    progress = Empeira::Progress.new(listener: ->(event) { events << event })
    expect(progress.run('Preparing') do
      progress.stage(30, 'Starting')
      :result
    end).to eq(:result)
    expect(events.map(&:percent)).to eq([0, 30, 100])
    expect(events.last.state).to eq(:complete)
    events.clear
    expect do
      progress.run('Preparing') do
        progress.stage(45, 'Database')
        raise Empeira::Error, 'synthetic'
      end
    end
      .to raise_error(Empeira::Error)
    expect(events.map(&:percent)).to eq([0, 45, 45])
    expect(events.last).to have_attributes(state: :failed, message: 'Failed: Database')
    expect do
      progress.run('Begin') do
        progress.stage(50, 'Wait')
        progress.stage(10, 'Backwards')
      end
    end
      .to raise_error(ArgumentError)
  end

  it 'renders line-oriented progress without terminal controls for redirected output' do
    io = StringIO.new
    renderer = Empeira::CLI::ProgressRenderer.new(io: io, interactive: false)
    progress = Empeira::Progress.new(listener: renderer)
    renderer.during { progress.run('Preparing') { progress.stage(30, 'Starting PuppetDB...') } }
    expect(io.string.lines.size).to eq(3)
    expect(io.string).to include('[  0%]', '[ 30%] Starting PuppetDB...', '[100%]')
    expect(io.string).not_to include("\e", "\r")
  end
end
