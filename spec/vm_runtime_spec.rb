# frozen_string_literal: true

require 'securerandom'

RSpec.describe Empeira::VM::QemuRuntime do
  let(:workspace) { Struct.new(:id).new(SecureRandom.hex(12)) }
  let(:locations) do
    Empeira::Platform::Locations.new(home: Dir.pwd, environment: {}, temporary_root: @directory)
  end
  let(:configuration) { { 'vm' => { 'console' => { 'root_password' => nil } } } }
  let(:context) do
    Struct.new(:workspace, :locations, :platform, :configuration).new(
      workspace, locations, Struct.new(:architecture).new(:amd64), configuration
    )
  end
  let(:engine) { instance_double(Empeira::VM::Qemu, accelerator: 'kvm', executable: '/usr/bin/qemu-system-x86_64') }
  let(:runtime) { described_class.new(engine: engine, runner: instance_double(Empeira::Execution::Runner), context: context) }
  let(:record) do
    { 'management_layout' => Empeira::VM::Management::VERSION, 'hostname' => 'host1', 'pid' => 12_345,
      'ssh_port' => 32_004, 'internet' => false,
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

  it 'attaches private VirtIO management without a management NIC or host ports' do
    arguments = runtime.send(:launch_arguments, record, '/tmp/disk.qcow2', '/tmp/seed.iso', [], '/tmp/monitor.sock')
    expect(arguments).to include('-accel', 'kvm', '-daemonize', '-serial', 'chardev:console',
                                 'virtio-serial-pci,id=management',
                                 "virtserialport,chardev=management,name=#{Empeira::VM::Management::CHANNEL}")
    expect(arguments.join(' ')).to include('guest.sock,server=on,wait=off')
    expect(arguments.join(' ')).not_to include('hostfwd', 'netdev=management', 'tcg', 'guestfwd')
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
    expect(runner).to receive(:console).with(runtime.console_path('host1'), guidance: include(
      "Connected to VM serial console.\nPress Ctrl+] to detach. The VM will keep running.\n",
      'No console password is configured. Use empeira node ssh host1 instead.'
    ))
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

  it 'rejects replaced, permissive and unrecorded management sockets before privilege or cleanup' do
    runtime.send(:prepare_monitor_directory, 'host1')
    socket_path = runtime.send(:management_path, 'host1')
    server = UNIXServer.new(socket_path)
    File.chmod(0o600, socket_path)
    allow(runtime).to receive(:running?).and_return(true)
    runtime.send(:capture_management_socket!, record)
    expect(runtime.management_socket(record)).to eq(socket_path)
    File.chmod(0o666, socket_path)
    expect { runtime.management_socket(record) }.to raise_error(Empeira::Providers::OwnershipError)
    File.chmod(0o600, socket_path)
    expect { runtime.management_socket(record.except('management_socket')) }
      .to raise_error(Empeira::Providers::OwnershipError)
    hidden = Pathname("#{socket_path}.original")
    File.rename(socket_path, hidden)
    replacement = UNIXServer.new(socket_path)
    File.chmod(0o600, socket_path)
    expect { runtime.management_socket(record) }.to raise_error(Empeira::Providers::OwnershipError)
    expect { runtime.cleanup(record.merge('pid' => nil)) }.to raise_error(Empeira::Providers::OwnershipError)
    expect(socket_path).to exist
  ensure
    replacement&.close
    server&.close
    File.unlink(socket_path) if socket_path&.socket?
    File.unlink(hidden) if hidden&.socket?
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
