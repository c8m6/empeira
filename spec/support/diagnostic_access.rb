# frozen_string_literal: true

require 'pty'
require 'io/console'

module LiveDiagnosticAccess
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- A real bidirectional PTY and terminal restoration share one test cleanup boundary.
  def diagnostic_shell(application, name:, commands:, rows: 29, columns: 101, controller: nil)
    master, terminal = PTY.open
    terminal.winsize = [rows, columns]
    original_echo = terminal.echo?
    transcript = +''
    reader = Thread.new do
      loop { transcript << master.readpartial(16_384) }
    rescue EOFError, Errno::EIO
      nil
    end
    allow(application.runner).to receive(:stream).and_wrap_original do |method, executable, **options|
      method.call(executable, **options, input: terminal, output: terminal, error: terminal)
    end
    allow(Empeira::VM::Guest).to receive(:new).and_wrap_original do |method, **options|
      method.call(**options).tap do |guest|
        allow(guest).to receive(:shell).and_wrap_original do |shell, record|
          shell.call(record, input: terminal, output: terminal)
        end
      end
    end
    # Container providers check the caller's terminal before using the native runtime.
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stdout).to receive(:tty?).and_return(true)
    keyboard = diagnostic_keyboard(controller, master, terminal, transcript)
    master.write(commands) unless commands.empty?
    result = Timeout.timeout(40) { application.nodes.shell(name: name) }
    expect(terminal.echo?).to eq(original_echo)
    keyboard&.value
    terminal.close
    reader.value
    [result, transcript]
  ensure
    allow(application.runner).to receive(:stream).and_call_original
    allow(Empeira::VM::Guest).to receive(:new).and_call_original
    [reader, keyboard].compact.each { |thread| thread.kill.join }
    [master, terminal].compact.each { |io| io.close unless io.closed? }
  end

  def diagnostic_keyboard(controller, master, terminal, transcript)
    return unless controller

    Thread.new do
      failed = true
      controller.call(master, terminal, transcript)
      failed = false
    ensure
      master.write("\x03\x04") if failed
    end
  end
end
