# frozen_string_literal: true

module LiveConsoleLogin
  # A real serial login exercises recovery while the SSH listener is stopped.
  # rubocop:disable-next Metrics/AbcSize -- Redirect and restore both ends of one real interactive session.
  def verify_console_login(app, name:)
    input, keyboard = IO.pipe
    screen, output = IO.pipe
    writer = Thread.new { drive_console(screen, keyboard) }
    allow(app.runner).to receive(:console).and_wrap_original do |original, path, **options|
      original.call(path, **options, input: input, output: output)
    end
    expect(app.nodes.shell(name: name)).to be_success
    expect(writer.value).to include('uid=0(root)')
  ensure
    writer&.kill&.join
    [input, keyboard, screen, output].compact.each { |stream| stream.close unless stream.closed? }
    allow(app.runner).to receive(:console).and_call_original
  end

  def drive_console(screen, keyboard)
    Timeout.timeout(60) do
      keyboard.write("\n")
      console_until(screen, /login:/)
      keyboard.write("root\n")
      console_until(screen, /Password:/)
      keyboard.write("empeira\n")
      console_until(screen, /root@.*# /)
      keyboard.write("id\npasswd -l root\nsystemctl start ssh.service\nexit\n")
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
