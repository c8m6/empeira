# frozen_string_literal: true

require 'base64'

RSpec.describe Empeira::VM::Guest do
  let(:record) { { 'management_layout' => Empeira::VM::Management::VERSION, 'peer' => { 'token' => 'a' * 32 } } }
  let(:path) { Pathname(@directory).join('guest.sock') }
  let(:qemu) { instance_double(Empeira::VM::QemuRuntime, management_socket: path) }
  let(:guest) { described_class.new(context: nil, runner: nil, qemu: qemu) }

  # rubocop:disable-next Metrics/AbcSize -- Exercise the production framed channel against an isolated peer.
  def serve
    server = UNIXServer.new(path)
    metadata = path.lstat
    record['management_socket'] = { 'device' => metadata.dev, 'inode' => metadata.ino }
    worker = Thread.new do
      socket = server.accept
      hello = JSON.parse(socket.gets)
      identity = hello.fetch('id')
      send = ->(frame) { socket.write("#{JSON.generate(frame.merge('id' => identity))}\n") }
      send.call('type' => 'hello', 'token' => record.fetch('peer').fetch('token'), 'version' => 1)
      yield socket, send
    ensure
      socket&.close
    end
    [server, worker]
  end

  after do
    @worker&.kill&.join
    @server&.close
  end

  [4, 6, 255].each do |status|
    it "returns confirmed guest exit #{status} with complete output rather than a transport error" do
      @server, @worker = serve do |socket, send|
        expect(JSON.parse(socket.gets)).to include('type' => 'exec', 'argv' => ['synthetic-command'])
        20.times { send.call('type' => 'stdout', 'data' => Base64.strict_encode64('x' * 16_384)) }
        send.call('type' => 'stderr', 'data' => Base64.strict_encode64('guest failure'))
        send.call('type' => 'exit', 'status' => status, 'timed_out' => false)
      end
      result = guest.run(record, ['synthetic-command'])
      expect(result.exit_status).to eq(status)
      expect(result.stdout.bytesize).to eq(327_680)
      expect(result.stderr).to eq('guest failure')
      @worker.value
    end
  end

  it 'streams output immediately and returns a confirmed timeout separately' do
    output = StringIO.new
    error = StringIO.new
    @server, @worker = serve do |socket, send|
      JSON.parse(socket.gets)
      send.call('type' => 'stdout', 'data' => Base64.strict_encode64('before completion'))
      Timeout.timeout(2) { Thread.pass until output.string == 'before completion' }
      send.call('type' => 'exit', 'status' => nil, 'timed_out' => true)
    end
    result = guest.stream(record, ['slow'], timeout: 1, output: output, error: error)
    expect(result.timed_out).to be(true)
    expect(result.exit_status).to be_nil
    @worker.value
  end

  it 'reports lost completion without replaying the guest operation' do
    @server, @worker = serve do |socket, _send|
      expect(JSON.parse(socket.gets)['type']).to eq('exec')
    end
    expect { guest.run(record, ['package-install']) }
      .to raise_error(described_class::TransportError, /completion is unknown.*retained/)
    @worker.value
  end

  it 'cancels the owned command on interruption and closes its private channel' do
    @server, @worker = serve do |socket, send|
      JSON.parse(socket.gets)
      send.call('type' => 'stdout', 'data' => Base64.strict_encode64('output'))
      expect(JSON.parse(socket.gets)['type']).to eq('cancel')
      send.call('type' => 'exit', 'status' => 130, 'timed_out' => false)
    end
    sink = instance_double(IO)
    allow(sink).to receive(:<<).and_raise(Interrupt)
    expect { guest.stream(record, ['slow'], output: sink) }.to raise_error(Interrupt)
    @worker.value
  end

  it 'uploads binary data with an integrity pin and requested mode' do
    source = Pathname(@directory).join('upload')
    source.binwrite("\0\xff" * 20_000)
    uploaded = +''.b
    @server, @worker = serve do |socket, send|
      expect(JSON.parse(socket.gets)['type']).to eq('upload')
      send.call('type' => 'ready')
      loop do
        frame = JSON.parse(socket.gets)
        if frame['type'] == 'chunk'
          uploaded << Base64.strict_decode64(frame.fetch('data'))
          send.call('type' => 'ready')
        else
          expect(frame).to include('type' => 'install', 'destination' => '/tmp/guest-file', 'mode' => '0600',
                                   'sha256' => Digest::SHA256.file(source).hexdigest)
          send.call('type' => 'exit', 'status' => 0, 'timed_out' => false)
          break
        end
      end
      expect(socket.gets).to be_nil
    end
    guest.copy_to(record, source, '/tmp/guest-file', mode: '0600')
    expect(uploaded).to eq(source.binread)
    @worker.value
  end

  it 'rejects another VM instance before command execution' do
    @server = UNIXServer.new(path)
    metadata = path.lstat
    record['management_socket'] = { 'device' => metadata.dev, 'inode' => metadata.ino }
    @worker = Thread.new do
      socket = @server.accept
      hello = JSON.parse(socket.gets)
      socket.write("#{JSON.generate(hello.merge('token' => 'b' * 32, 'version' => 1))}\n")
      expect(socket.gets).to be_nil
    ensure
      socket&.close
    end
    expect { guest.run(record, ['true']) }.to raise_error(Empeira::Providers::OwnershipError, /identity mismatch/)
    @worker.value
  end
end
