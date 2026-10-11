# frozen_string_literal: true

module Empeira
  module Runtime
    module DiagnosticExecution
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Stream, cancellation receipt and pipe closure share one transaction.
      def diagnostic_exec(resource, arguments, timeout: nil, output: $stdout, error: $stderr)
        token = SecureRandom.hex(16)
        code = Pathname(__dir__).join('../../../resources/nodes/diagnostic_exec.rb').read
        IO.pipe do |input, control|
          native = runner.controlled_stream(name, arguments: ['exec', '--interactive', '--user', '0',
                                                              resource.fetch('id'), ControlPlane::Health::RUBY,
                                                              '-e', code, '--', 'run', token,
                                                              timeout ? timeout.to_s : 'none', *arguments],
                                                  input: input, control: control, output: output, error: error)
          diagnostic_completion(resource, code, token, native)
        rescue SignalException
          native = Execution::Result.new(stdout: '', stderr: '', exit_status: 130, timed_out: false)
          diagnostic_completion(resource, code, token, native)
          raise
        ensure
          control.close unless control.closed?
        end
      end

      private

      def valid_diagnostic_completion?(data)
        data.is_a?(Hash) && [true, false].include?(data['timed_out']) &&
          ((data['status'].is_a?(Integer) && data['status'].between?(0, 255)) ||
            (data['status'].nil? && data['timed_out']))
      end

      def diagnostic_completion(resource, code, token, native)
        result = runner.run(name, arguments: ['exec', '--user', '0', resource.fetch('id'),
                                              ControlPlane::Health::RUBY, '-e', code, '--', 'read', token], timeout: 10)
        data = JSON.parse(result.stdout) if result.success?
        if valid_diagnostic_completion?(data)
          return Execution::Result.new(stdout: '', stderr: '', exit_status: data['status'],
                                       timed_out: data['timed_out'])
        end

        details = Execution::Diagnostics.command(native, operation: 'Container diagnostic transport', tool: name)
        raise Error, "Container command completion or cancellation is unconfirmed; node retained\n#{details}"
      rescue JSON::ParserError
        raise Error, 'Container command completion is malformed; node retained', cause: nil
      end
    end
  end
end

Empeira::Runtime::Container.include(Empeira::Runtime::DiagnosticExecution)
