# frozen_string_literal: true

module Empeira
  module VM
    # Frame output is drained without truncation; streaming sinks receive it before completion.
    class GuestOutput
      def initialize(output: nil, error: nil)
        @stdout = +''.b
        @stderr = +''.b
        @output = output || @stdout
        @error = error || @stderr
      end

      def consume(channel, timeout:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          frame = channel.receive(timeout: deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          case frame['type']
          when 'started' then next
          when 'stdout', 'stderr' then emit(frame)
          when 'exit' then return completion(frame)
          else raise Error, 'VM management returned an unexpected protocol message'
          end
        end
      rescue ArgumentError, KeyError
        raise Error, 'VM management returned malformed output data', cause: nil
      end

      private

      def emit(frame)
        sink = frame['type'] == 'stdout' ? @output : @error
        sink << Base64.strict_decode64(frame.fetch('data'))
        sink.flush if sink.respond_to?(:flush)
      end

      def completion(frame)
        status, timed_out = frame.values_at('status', 'timed_out')
        unless [true, false].include?(timed_out) &&
               ((status.is_a?(Integer) && status.between?(0, 255)) || (status.nil? && timed_out))
          raise Error, 'VM management returned invalid guest completion status'
        end

        Execution::Result.new(stdout: @stdout, stderr: @stderr, exit_status: status, timed_out: timed_out)
      end
    end
  end
end
