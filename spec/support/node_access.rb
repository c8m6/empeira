# frozen_string_literal: true

require_relative 'diagnostic_access'

# Feed real interactive clients a short session while keeping central process execution.
module LiveNodeAccess
  include LiveDiagnosticAccess

  def verify_ssh_session(app, name:, user:, identity: nil, override_user: nil)
    options = { identity: identity&.to_s, user: override_user }.compact
    status, output, error = access_session(app, name: name, operation: :ssh, **options)
    expect(status.exit_status).to eq(7), error
    expect(output).to match(%r{^/dev/pts/\d+\r?$})
    expect(output).to match(/^#{user}\r?$/)
    expect(output).to match(/^connection=\S.+\r?$/)
  end

  def verify_exec_session(app, name:)
    commands = "tty\nwhoami\nprintf 'connection=%s\\n' \"$SSH_CONNECTION\"\nexit 7\n"
    status, output = diagnostic_shell(app, name: name, commands: commands)
    output = clean_session_output(output)
    expect(status.exit_status).to eq(7)
    expect(output).to match(/^root\r?$/)
    expect(output).to match(/^connection=\r?$/)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Redirect only the interactive stream and restore it after the real session.
  def access_session(app, name:, operation:, commands: nil, **options)
    if operation == :shell
      status, output = diagnostic_shell(app, name: name, commands: commands || "whoami\nexit 7\n")
      return [status, clean_session_output(output), '']
    end

    streams = Array.new(3) { Tempfile.new('node-session-') }
    input, output, error = streams
    input.write(commands || "tty\nwhoami\nprintf 'connection=%s\\n' \"$SSH_CONNECTION\"\nexit 7\n")
    input.rewind
    allow(app.runner).to receive(:stream).and_wrap_original do |original, executable, **options|
      original.call(executable, **options, environment: { 'SSH_AUTH_SOCK' => nil },
                                           input: input, output: output, error: error)
    end
    status = app.nodes.public_send(operation, name: name, **options)
    output.rewind
    error.rewind
    [status, clean_session_output(output.read), error.read]
  ensure
    allow(app.runner).to receive(:stream).and_call_original
    streams&.each(&:close!)
  end

  def clean_session_output(output)
    output.gsub(%r{\e\[[0-?]*[ -/]*[@-~]}, '').gsub(/\e\][^\a]*(?:\a|\e\\)/, '').delete("\r")
  end
end
