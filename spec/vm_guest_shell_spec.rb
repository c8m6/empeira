# frozen_string_literal: true

require 'pty'
require 'io/console'

RSpec.describe Empeira::VM::GuestShell do
  let(:runner) { Empeira::Execution::Runner.new }

  it 'refuses non-TTY input before connecting a privileged management session' do
    qemu = double('owned VM')
    expect(qemu).not_to receive(:with_management_socket)
    guest = Empeira::VM::Guest.new(context: nil, runner: runner, qemu: qemu)
    expect { guest.shell({}, input: StringIO.new, output: StringIO.new) }
      .to raise_error(Empeira::Error, /local terminal/)
  end

  %w[INT TERM HUP QUIT TSTP].each do |signal|
    it "restores the local terminal and confirms guest cancellation after SIG#{signal}" do
      path = Pathname(@directory).join('guest.sock')
      server = UNIXServer.new(path)
      File.chmod(0o600, path)
      master, terminal = PTY.open
      terminal.winsize = [31, 97]
      original_echo = terminal.echo?
      connected = Queue.new
      peer = Thread.new do
        socket = server.accept
        hello = JSON.parse(socket.gets)
        id = hello.fetch('id')
        send_frame = ->(frame) { socket.puts(JSON.generate(frame.merge('id' => id))) }
        send_frame.call('type' => 'hello', 'version' => Empeira::VM::Management::VERSION,
                        'token' => 'a' * 32)
        shell = JSON.parse(socket.gets)
        expect(shell).to include('type' => 'shell', 'size' => [31, 97])
        send_frame.call('type' => 'started')
        send_frame.call('type' => 'ready')
        connected << true
        expect(JSON.parse(socket.gets)).to include('type' => 'cancel')
        send_frame.call('type' => 'exit', 'status' => 130, 'timed_out' => false)
        expect(socket.read).to eq('')
      ensure
        socket&.close
      end
      code = <<~RUBY
        require 'empeira'
        $stdout.sync = true
        puts Process.pid
        path = Pathname(ARGV.fetch(0))
        expected = { 'device' => path.lstat.dev, 'inode' => path.lstat.ino }
        qemu = Object.new
        qemu.define_singleton_method(:with_management_socket) { |_record, &block| block.call(path, expected) }
        record = { 'management_layout' => Empeira::VM::Management::VERSION, 'peer' => { 'token' => 'a' * 32 } }
        Empeira::VM::Guest.new(context: nil, runner: Empeira::Execution::Runner.new, qemu: qemu).shell(record)
      RUBY
      worker = Thread.new do
        runner.stream(RbConfig.ruby, arguments: ['-I', File.expand_path('../lib', __dir__), '-e', code, path.to_s],
                                     input: terminal, output: terminal, error: terminal)
      end
      pid = Integer(Timeout.timeout(5) { master.gets }, 10)
      transcript = +''
      screen = Thread.new { loop { transcript << master.readpartial(16_384) } }
      Timeout.timeout(5) { connected.pop }
      Timeout.timeout(5) { sleep 0.01 while terminal.echo? == original_echo }
      Process.kill(signal, pid)
      expect(worker.join(5)).not_to be_nil, transcript
      expect(worker.value.exit_status).to eq(128 + Signal.list.fetch(signal))
      expect(terminal.echo?).to eq(original_echo)
      peer.value
    ensure
      [worker, peer, screen].compact.each { |thread| thread.kill.join }
      [server, master, terminal].compact.each { |io| io.close unless io.closed? }
    end
  end

  it 'preserves terminal modes after malformed frames or an unexpected EOF' do
    master, terminal = PTY.open
    original_echo = terminal.echo?
    input, output = IO.pipe
    channel = double('failed transport', io: input, readable?: true)
    allow(channel).to receive(:send_frame)
    allow(channel).to receive(:receive).and_raise(EOFError)
    expect { described_class.new(input: terminal, output: terminal).consume(channel) }.to raise_error(EOFError)
    expect(terminal.echo?).to eq(original_echo)
  ensure
    [master, terminal, input, output].compact.each(&:close)
  end
end
