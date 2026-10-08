# frozen_string_literal: true

require 'securerandom'

RSpec.describe Empeira::VM::QemuRuntime do
  let(:workspace) { Struct.new(:id).new(SecureRandom.hex(12)) }
  let(:locations) do
    Empeira::Platform::Locations.new(home: Dir.pwd, environment: {}, temporary_root: @directory)
  end
  let(:context) do
    Struct.new(:workspace, :locations, :platform).new(
      workspace, locations, Struct.new(:architecture).new(:amd64)
    )
  end
  let(:engine) { instance_double(Empeira::VM::Qemu, accelerator: 'kvm', executable: '/usr/bin/qemu-system-x86_64') }
  let(:runtime) { described_class.new(engine: engine, runner: instance_double(Empeira::Execution::Runner), context: context) }
  let(:record) do
    { 'hostname' => 'host1', 'pid' => 12_345, 'ssh_port' => 32_004, 'internet' => false,
      'peer' => { 'token' => 'a' * 32 }, 'mac_address' => '52:54:00:12:34:56', 'memory' => 1024, 'cpus' => 2 }
  end

  after do
    directory = runtime.send(:monitor_directory, 'host1')
    FileUtils.remove_entry(directory) if directory.directory?
  end

  it 'refuses a second launch while its recorded process exists and protects the monitor directory' do
    allow(Process).to receive(:kill).with(0, 12_345).and_return(1)
    expect do
      runtime.launch(record: record, overlay: Pathname(@directory).join('disk.qcow2'),
                     seed: Pathname(@directory).join('seed.iso'), network: instance_double(Empeira::Network::Peer::Attachment))
    end.to raise_error(Empeira::Error, /second launch/)
    directory = runtime.send(:monitor_directory, 'host1')
    expect(File.stat(directory).mode & 0o077).to eq(0)
  end

  it 'uses a short private monitor location when the temporary directory is too long' do
    allow(locations).to receive(:temporary).and_return(Pathname("/#{'x' * 120}"))
    directory = runtime.send(:monitor_directory, 'host1')
    expect(directory.dirname).to eq(Pathname(Dir.pwd))
    expect(directory.join('monitor.sock').to_s.bytesize).to be <= 100
  end

  it 'removes the private fallback monitor directory after the VM stops' do
    allow(locations).to receive(:temporary).and_return(Pathname("/#{'x' * 120}"))
    directory = runtime.send(:monitor_directory, 'host1')
    runtime.send(:prepare_monitor_directory, 'host1')
    runtime.cleanup(record.merge('pid' => nil))
    expect(directory).not_to exist
  end

  it 'passes the restricted SSH-only management network into QEMU launch arguments' do
    network = Empeira::Network::Peer::Management.new(record).arguments
    arguments = runtime.send(:launch_arguments, record, '/tmp/disk.qcow2', '/tmp/seed.iso', network,
                             '/tmp/monitor.sock')
    expect(arguments).to include('-accel', 'kvm', '-daemonize', '-netdev', '-serial', 'chardev:console')
    expect(arguments[arguments.index('-chardev') + 1]).to include('server=on,wait=off', 'console.sock', 'logappend=on')
    expect(arguments[arguments.index('-netdev') + 1]).to include('restrict=on', 'hostfwd=tcp:127.0.0.1:32004-:22')
    expect(arguments.join(' ')).not_to include('3128', 'tcg', 'guestfwd')
  end
  it 'isolates console endpoints by node and workspace with macOS-safe paths' do
    first = runtime.console_path('host1')
    expect(first.to_s.bytesize).to be <= 100
    expect(runtime.console_path('host2')).not_to eq(first)
    workspace.id = SecureRandom.hex(12)
    expect(runtime.console_path('host1')).not_to eq(first)
  end

  it 'attaches to the existing console and removes its endpoint on cleanup' do
    runtime.send(:prepare_monitor_directory, 'host1')
    server = UNIXServer.new(runtime.console_path('host1'))
    allow(runtime).to receive(:running?).and_return(true)
    runner = runtime.instance_variable_get(:@runner)
    expect(runner).not_to receive(:run)
    expect(runner).to receive(:console).with(runtime.console_path('host1'))
    runtime.console(record)
    server.close
    runtime.cleanup(record.merge('pid' => nil))
    expect(runtime.console_path('host1')).not_to exist
  ensure
    server&.close unless server&.closed?
  end

  it 'rejects stopped VMs and unsafe console endpoints before attaching' do
    allow(runtime).to receive(:running?).and_return(false)
    expect { runtime.console(record) }.to raise_error(Empeira::Error, /stopped/)
    runtime.send(:prepare_monitor_directory, 'host1')
    File.write(runtime.console_path('host1'), 'unexpected file')
    allow(runtime).to receive(:running?).and_return(true)
    expect { runtime.console(record) }.to raise_error(Empeira::Providers::OwnershipError)
    expect { runtime.cleanup(record.merge('pid' => nil)) }.to raise_error(Empeira::Error, /cleanup refused/)
  end

  it 'waits for the monitor greeting and command acknowledgement before disconnecting' do
    directory = runtime.send(:monitor_directory, 'host1')
    runtime.send(:prepare_monitor_directory, 'host1')
    server = UNIXServer.new(directory.join('monitor.sock'))
    commands = Queue.new
    peer = Thread.new do
      socket = server.accept
      socket.write("QEMU monitor\r\n(qemu) ")
      expect(socket.gets).to eq("info name\n")
      socket.write("#{runtime.send(:process_name, record)}\r\n(qemu) ")
      commands << socket.gets
      sleep 0.02
      socket.write("\r\n(qemu) ")
      expect(socket.read).to eq('')
    ensure
      socket&.close
    end
    runtime.send(:monitor_command, record, 'system_powerdown')
    peer.value
    expect(commands.pop).to eq("system_powerdown\n")
  ensure
    peer&.kill&.join
    server&.close
  end

  it 'refuses to control a monitor belonging to another instance' do
    runtime.send(:prepare_monitor_directory, 'host1')
    server = UNIXServer.new(runtime.send(:monitor_path, 'host1'))
    peer = Thread.new do
      socket = server.accept
      socket.write("QEMU monitor\r\n(qemu) ")
      expect(socket.gets).to eq("info name\n")
      socket.write("another-instance\r\n(qemu) ")
      expect(socket.read).to eq('')
    ensure
      socket&.close
    end
    expect { runtime.send(:monitor_command, record, 'quit') }.to raise_error(Empeira::Providers::OwnershipError)
    peer.value
  ensure
    peer&.kill&.join
    server&.close
  end
end
