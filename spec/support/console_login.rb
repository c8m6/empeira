# frozen_string_literal: true

module LiveConsoleLogin
  # A real serial login exercises recovery while the SSH listener is stopped.
  # rubocop:disable-next Metrics/AbcSize -- Redirect and restore both ends of one real interactive session.
  def verify_console_login(app, name:, commands: nil)
    input, keyboard = IO.pipe
    screen, output = IO.pipe
    writer = Thread.new { drive_console(screen, keyboard, commands: commands) }
    allow(app.runner).to receive(:console).and_wrap_original do |original, path, **options|
      original.call(path, **options, input: input, output: output)
    end
    expect(app.nodes.shell(name: name)).to be_success
    result = writer.value
    expect(result).to include('uid=0(root)')
    result
  ensure
    writer&.kill&.join
    [input, keyboard, screen, output].compact.each { |stream| stream.close unless stream.closed? }
    allow(app.runner).to receive(:console).and_call_original
  end

  def drive_console(screen, keyboard, commands: nil)
    Timeout.timeout(60) do
      keyboard.write("\n")
      console_until(screen, /login:/)
      keyboard.write("root\n")
      console_until(screen, /Password:/)
      keyboard.write("empeira\n")
      console_until(screen, /root@.*# /)
      keyboard.write(commands || "id\nusermod --password '*' root\nsystemctl start ssh.service\nexit\n")
      result = console_until(screen, /login:/)
      keyboard.write("\x1d")
      result
    end
  ensure
    keyboard.close
  end

  def console_until(screen, pattern)
    buffer = +''
    buffer << screen.readpartial(4096) until buffer.match?(pattern)
    buffer
  end
end
