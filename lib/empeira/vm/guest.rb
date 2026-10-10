# frozen_string_literal: true

module Empeira
  module VM
    # Shared guest execution/upload/readiness API; no host or guest SSH credentials.
    class Guest
      class TransportError < Error
        attr_reader :timed_out

        def initialize(message, transient: false, timed_out: false)
          @timed_out = timed_out
          @transient = transient
          super(message)
        end

        def transient? = @transient

        def with_context(message)
          self.class.new("#{message}\n#{self.message}", transient: transient?, timed_out: timed_out)
        end
      end

      def initialize(context:, runner:, qemu:)
        @context = context
        @runner = runner
        @qemu = qemu
      end

      def run(record, arguments, timeout: 30)
        execute(record, arguments, timeout: timeout)
      end

      def stream(record, arguments, timeout: 3600, output: $stdout, error: $stderr)
        execute(record, arguments, timeout: timeout, output: output, error: error)
      end

      def copy_to(record, source, destination, mode: '0644')
        File.open(source, 'rb') do |file|
          transfer(record) { |channel| GuestUpload.new(channel).write(file, destination, mode: mode) }
        end
      end

      # rubocop:disable-next Metrics/MethodLength -- Readiness alone retries harmless status probes before bootstrap.
      def wait(record, progress: nil, seconds: 300)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          begin
            result = run(record, ['cloud-init', 'status', '--wait', '--long'], timeout: 20)
            return if result.success?

            details = Execution::Diagnostics.command(result, operation: 'VM cloud-init readiness',
                                                             tool: 'VirtIO management')
          rescue TransportError => e
            details = e.message
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise Error,
                  "VM management or cloud-init did not become ready; inspect node shell and serial log\n#{details}"
          end

          progress&.heartbeat('Waiting for VM management and cloud-init...')
          sleep 2
        end
      end

      private

      def execute(record, arguments, timeout:, output: nil, error: nil)
        validate_command!(arguments, timeout)

        transfer(record) do |channel|
          channel.send_frame('type' => 'exec', 'argv' => arguments, 'timeout' => timeout)
          GuestOutput.new(output: output, error: error).consume(channel, timeout: timeout + 5)
        end
      end

      def validate_command!(arguments, timeout)
        unless arguments.is_a?(Array) && !arguments.empty? && arguments.all? do |arg|
          arg.is_a?(String) && !arg.include?("\0")
        end
          raise ExecutionError, 'Guest command arguments must be nonempty strings without null bytes'
        end

        validate_timeout!(timeout)
      end

      def validate_timeout!(timeout)
        return if timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? && timeout <= 86_400

        raise ExecutionError, 'Guest timeout must be positive and at most one day'
      end

      # rubocop:disable-next Metrics/MethodLength -- Completion and cancellation must share the same ensure boundary.
      def transfer(record)
        Management.validate!(record)
        GuestChannel.new(record: record, qemu: @qemu).open do |channel|
          completed = false
          begin
            value = yield channel
            completed = true
            value
          ensure
            channel.cancel unless completed
          end
        end
      rescue SystemCallError, IOError, Timeout::Error => e
        raise TransportError.new("VM VirtIO management transport failed (#{e.class.name}); " \
                                 'guest completion is unknown; ' \
                                 'VM retained. Inspect node shell, serial log and the management service journal.',
                                 transient: e.is_a?(Errno::ENOENT) || e.is_a?(Errno::ECONNREFUSED),
                                 timed_out: e.is_a?(Timeout::Error)), cause: nil
      end
    end
  end
end
