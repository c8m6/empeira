# frozen_string_literal: true

require 'open3'
require 'timeout'

module Empeira
  module Execution
    # rubocop:disable-next Metrics/ClassLength -- Capture, process streams and direct consoles share one execution boundary.
    class Runner
      def initialize(platform: Platform::Facts.new, logger: nil)
        @platform = platform
        @logger = logger
      end

      def run(executable, arguments: [], environment: {}, directory: nil, timeout: nil, on_stdout: nil)
        validate!(executable, arguments, environment, timeout)
        log(arguments, environment)
        options = { pgroup: true }
        options[:chdir] = directory.to_s if directory
        result = capture(environment, executable, arguments, options, timeout, on_stdout)
        @logger&.debug({ operation: 'execute', exit_status: result.exit_status, timed_out: result.timed_out })
        result
      rescue SystemCallError => e
        # OS exception messages can include command arguments and credentials.
        raise ExecutionError, "Process could not be executed (#{e.class.name})", cause: nil
      end

      # Inherit caller streams for terminals and unbounded logs; never buffer them.
      # Explicit stream handles avoid hidden globals in process-execution tests.
      # rubocop:disable-next Metrics/ParameterLists
      def stream(executable, arguments: [], environment: {}, directory: nil,
                 input: $stdin, output: $stdout, error: $stderr)
        validate!(executable, arguments, environment, nil)
        log(arguments, environment)
        options = { in: input, out: output, err: error }
        options[:chdir] = directory.to_s if directory
        pid = Process.spawn(environment, [executable, executable], *arguments, **options)
        _, status = Process.wait2(pid)
        pid = nil
        Result.new(stdout: '', stderr: '', exit_status: status.exitstatus || (128 + status.termsig), timed_out: false)
      rescue SystemCallError => e
        raise ExecutionError, "Streaming process could not execute (#{e.class.name})", cause: nil
      ensure
        reap_stream(pid) if pid
      end

      def console(path, input: $stdin, output: $stdout, guidance: nil)
        Console.new.attach(path, input: input, output: output, guidance: guidance)
      end

      def debug(message)
        @logger&.debug(message)
      end

      # Keep the caller's input and foreground terminal for authentication, but capture tool output.
      # rubocop:disable-next Metrics/AbcSize -- Paired pipes and reader cleanup bracket one foreground process.
      def buffered(executable, arguments: [], environment: {}, directory: nil, input: $stdin)
        IO.pipe do |stdout, output|
          IO.pipe do |stderr, error|
            readers = [stdout, stderr].map { |io| Thread.new { io.binmode.read } }
            result = stream(executable, arguments: arguments, environment: environment, directory: directory,
                                        input: input, output: output, error: error)
            output.close
            error.close
            Result.new(stdout: readers[0].value, stderr: readers[1].value,
                       exit_status: result.exit_status, timed_out: result.timed_out)
          ensure
            readers&.each { |thread| thread.kill.join }
          end
        end
      end

      private

      def reap_stream(pid)
        Process.kill('TERM', pid)
        Timeout.timeout(2) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def validate!(executable, arguments, environment, timeout)
        unless command_string?(executable) && !executable.empty? &&
               arguments.is_a?(Array) && arguments.all? { |arg| command_string?(arg) }
          raise ExecutionError, 'Executable and arguments must be strings without null bytes'
        end

        validate_environment!(environment)
        validate_timeout!(timeout)
      end

      def command_string?(value)
        value.is_a?(String) && !value.include?("\0")
      end

      def validate_environment!(environment)
        return if environment.is_a?(Hash) && environment.all? { |key, value| environment_entry?(key, value) }

        raise ExecutionError, 'Environment must map valid variable names to strings or null'
      end

      def environment_entry?(key, value)
        command_string?(key) && !key.empty? && !key.include?('=') && (value.nil? || command_string?(value))
      end

      def validate_timeout!(timeout)
        return if timeout.nil? || (timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?)

        raise ExecutionError, 'Timeout must be a positive finite number'
      end

      def log(arguments, environment)
        @logger&.debug({ operation: 'execute', arguments: arguments.map { '[REDACTED]' },
                         environment: environment.transform_values { '[REDACTED]' } })
      end

      def capture(environment, executable, arguments, options, timeout, on_stdout)
        # The two-element executable form prevents Ruby's single-string shell fallback.
        Open3.popen3(environment, [executable, executable], *arguments, **options) do |stdin, stdout, stderr, process|
          completed = false
          stdin.close
          streams = [Thread.new { read_output(stdout, on_stdout) }, Thread.new { stderr.binmode.read }]
          result = collect(process, streams, timeout)
          completed = true
          result
        ensure
          cleanup(process, streams, completed)
        end
      end

      def read_output(io, observer)
        return io.binmode.read unless observer

        buffer = +''.b
        loop do
          chunk = io.readpartial(16_384)
          buffer << chunk
          observer.call(chunk)
        end
      rescue EOFError
        buffer
      end

      def collect(process, streams, timeout)
        Timeout.timeout(timeout) do
          status = process.value
          Result.new(stdout: streams[0].value.freeze, stderr: streams[1].value.freeze,
                     exit_status: status.exitstatus, timed_out: false)
        end
      rescue Timeout::Error
        timed_out(process, streams)
      end

      def timed_out(process, streams)
        terminate(process.pid)
        process.join
        output = streams.map { |stream| stream.join(1) ? stream.value : '' }
        Result.new(stdout: output[0], stderr: output[1], exit_status: nil, timed_out: true)
      end

      def cleanup(process, streams, completed)
        unless completed
          # A reaped group leader does not mean its descendants have exited.
          terminate(process.pid)
          process.join
        end
      ensure
        streams&.each { |thread| thread.kill.join }
      end

      def terminate(pid)
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
