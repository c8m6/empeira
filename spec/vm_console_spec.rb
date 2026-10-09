# frozen_string_literal: true

RSpec.describe Empeira::Execution::Console do
  it 'relays direct console input/output and detaches with Ctrl-] without sending it to the guest' do
    path = File.join(@directory, 'console.sock')
    server = UNIXServer.new(path)
    input, keyboard = IO.pipe
    output = Tempfile.new('console-output')
    received = Queue.new
    peer = Thread.new do
      connection = server.accept
      connection.write("console prompt\n")
      received << connection.read(5)
      expect(connection.read).to eq('')
    ensure
      connection&.close
    end
    writer = Thread.new do
      keyboard.write('hello')
      expect(received.pop).to eq('hello')
      keyboard.write("\x1d")
    end
    result = Empeira::Execution::Runner.new.console(path, input: input, output: output)
    expect(result).to be_success
    writer.value
    peer.value
    output.rewind
    expect(output.read).to include('console prompt')
  ensure
    [writer, peer].compact.each { |thread| thread.kill.join }
    [server, input, keyboard].compact.each(&:close)
    output&.close!
  end

  it 'prints connection guidance and closes the console after a peer disconnect' do
    path = File.join(@directory, 'console.sock')
    server = UNIXServer.new(path)
    input, keyboard = IO.pipe
    output = Tempfile.new('console-output')
    peer = Thread.new { server.accept.close }
    result = Empeira::Execution::Runner.new.console(path, input: input, output: output,
                                                          guidance: "Connected to VM serial console.\n")
    expect(result).to be_success
    peer.value
    output.rewind
    expect(output.read).to eq("Connected to VM serial console.\n")
  ensure
    peer&.kill&.join
    [server, input, keyboard].compact.each(&:close)
    output&.close!
  end

  %w[INT TERM].each do |signal|
    it "restores an actual terminal and closes the socket on SIG#{signal}" do
      require 'pty'
      require 'io/console'
      path = File.join(@directory, 'console.sock')
      server = UNIXServer.new(path)
      master, input = PTY.open
      screen, output = IO.pipe
      original_echo = input.echo?
      peer = Thread.new do
        socket = server.accept
        expect(socket.read).to eq('')
      ensure
        socket&.close
      end
      code = 'require "empeira"; $stdout.sync = true; puts Process.pid; ' \
             'Empeira::Execution::Runner.new.console(ARGV.fetch(0))'
      worker = Thread.new do
        Empeira::Execution::Runner.new.stream(RbConfig.ruby,
                                              arguments: ['-I', File.expand_path('../lib', __dir__), '-e', code, path],
                                              input: input, output: output, error: output)
      end
      pid = Integer(Timeout.timeout(5) { screen.gets }, 10)
      Timeout.timeout(5) { sleep 0.01 while input.echo? == original_echo }
      Process.kill(signal, pid)
      expect(worker.join(5)).not_to be_nil
      expect(worker.value.exit_status).to eq(128 + Signal.list.fetch(signal))
      expect(input.echo?).to eq(original_echo)
      peer.value
    ensure
      [worker, peer].compact.each { |thread| thread.kill.join }
      [master, input, server, screen, output].compact.each { |io| io.close unless io.closed? }
    end
  end
end

RSpec.describe 'VM console configuration' do
  [nil, 'empeira', 'synthetic-private-password'].each do |password|
    it "keeps the initial password separate from SSH and state (enabled=#{!password.nil?})" do
      File.write(File.join(@directory, '.empeira.yaml'),
                 YAML.dump('vm' => { 'console' => { 'root_password' => password } }))
      app = Empeira::Application.new(project_path: @directory)
      cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
      record = { 'hostname' => 'node', 'os' => 'ubuntu', 'version' => '24.04' }
      data = cloud.send(:cloud_config, record, 'synthetic-public-key')
      expect(data['ssh_pwauth']).to be(false)
      if password
        expect(data.dig('chpasswd', 'users').first).to include('name' => 'root', 'password' => password)
      else
        expect(data).not_to have_key('chpasswd')
      end
      expect(cloud.send(:cloud_config, record, 'public-key', console: false)).not_to have_key('chpasswd')
      redacted = Empeira::Configuration::Display.redact(app.context.configuration)
      expect(redacted.dig('vm', 'console', 'root_password')).to eq('[REDACTED]')
      metadata = Empeira::Infrastructure::Definition.new(context: app.context).metadata.to_s
      expect(metadata).not_to include('root_password', 'synthetic-private-password')
    end
  end
end
