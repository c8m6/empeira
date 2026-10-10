# frozen_string_literal: true

require 'yaml'

RSpec.describe Empeira::VM::CloudInit do
  let(:success) do
    Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
  end

  it 'seeds deterministic guest networking and project-local scripts without placing private keys in user-data' do
    script = File.join(@directory, 'bootstrap.sh')
    File.write(script, "#!/bin/sh\nprintf ready\n")
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('bootstrap' => { 'enabled' => true, 'scripts' => ['bootstrap.sh'],
                                          'guests' => { 'ubuntu' => { '24.04' => {
                                            'archive' => 'https://archive.example.test/ubuntu',
                                            'security' => 'https://security.example.test/ubuntu',
                                            'ports' => 'https://ports.example.test/ubuntu-ports'
                                          } } } },
                         'server' => { 'mounts' => [{ 'source' => 'bootstrap.sh',
                                                      'target' => '/srv/server-only.sh' }] }))
    app = Empeira::Application.new(project_path: @directory,
                                   locations: Empeira::Platform::Locations.new(
                                     home: File.join(@directory, 'user-home'), environment: {}
                                   ))
    %w[xorriso ssh-keygen].each do |name|
      file = File.join(@directory, name)
      File.write(file, '')
      File.chmod(0o755, file)
    end
    runner = instance_double(Empeira::Execution::Runner)
    allow(runner).to receive(:run) do |_executable, arguments:, **_options|
      if arguments.include?('-t')
        key = arguments.fetch(arguments.index('-f') + 1)
        File.write(key, 'synthetic private key')
        File.write("#{key}.pub", 'ssh-ed25519 synthetic-public-key')
      else
        output = arguments.fetch(arguments.index('-output') + 1)
        File.write(output, 'synthetic ISO')
      end
      success
    end
    cloud = described_class.new(context: app.context, runner: runner, executable_path: @directory)
    record = { 'os' => 'ubuntu', 'version' => '24.04', 'management_layout' => Empeira::VM::Management::VERSION,
               'hostname' => 'host1', 'mac_address' => '52:54:00:12:34:56',
               'peer' => { 'token' => 'a' * 32, 'gateway' => '10.200.30.2', 'ip' => '10.203.20.32',
                           'dns' => '10.203.20.130' } }
    captured = nil
    allow(cloud).to receive(:create_iso).and_wrap_original do |original, directory, files|
      captured = files.to_h { |file| [file.basename.to_s, file.read] }
      original.call(directory, files)
    end
    expect(cloud.prepare(record)).to exist
    directory = app.context.locations.workspace(app.context.workspace).join('vms', 'host1')
    expect(File.stat(directory.join('seed.iso')).mode & 0o077).to eq(0)
    expect(File.stat(directory.join('id_ed25519')).mode & 0o077).to eq(0)
    expect(directory.join('user-data')).not_to exist
    user_data = captured.fetch('user-data')
    parsed = YAML.safe_load(user_data.delete_prefix("#cloud-config\n"))
    expect(parsed['write_files'].map { |entry| entry['path'] }).to include(
      '/etc/sysctl.d/90-empeira-ipv4.conf', '/usr/local/libexec/empeira-bootstrap-0',
      Empeira::Node::ExternalFact::PATH
    )
    fact = parsed['write_files'].find { |entry| entry['path'] == Empeira::Node::ExternalFact::PATH }
    expect(fact).to include('permissions' => '0644', 'content' => "empeira:\n  provider: vm\n")
    expect(parsed['runcmd'].last).to eq(['/usr/local/libexec/empeira-bootstrap-0'])
    expect(parsed).not_to have_key('apt')
    expect(user_data).not_to include('synthetic private key', 'dns-forward', 'archive.example.test',
                                     'preserve_sources_list')
    expect(parsed).not_to have_key('mounts')
    expect(captured.values.join).not_to include('/srv/server-only.sh')
    network = YAML.safe_load(captured.fetch('network-config'))
    expect(network.dig('ethernets', 'peer', 'nameservers', 'addresses')).to eq(['10.203.20.130'])
    expect(network.fetch('ethernets').keys).to eq(['peer'])
  end

  it 'rejects bootstrap scripts that resolve outside the project' do
    external = File.join(Dir.tmpdir, "empeira-external-#{Process.pid}.sh")
    File.write(external, '#!/bin/sh')
    File.symlink(external, File.join(@directory, 'bootstrap.sh'))
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('bootstrap' => { 'enabled' => true, 'scripts' => ['bootstrap.sh'] }))
    app = Empeira::Application.new(project_path: @directory)
    cloud = described_class.new(context: app.context, runner: instance_double(Empeira::Execution::Runner))
    expect { cloud.send(:bootstrap_files) }.to raise_error(Empeira::ConfigurationError, /bootstrap.scripts.0/)
  ensure
    File.unlink(external) if external && File.exist?(external)
  end
end
