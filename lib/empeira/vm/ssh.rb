# frozen_string_literal: true

require 'securerandom'
require 'shellwords'

module Empeira
  module VM
    # Internal management transport for provisioning and Puppet operations.
    class SSH
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

      def initialize(context:, runner:, cloud_init:, executable_path: ENV.fetch('PATH', ''))
        @context = context
        @runner = runner
        @cloud_init = cloud_init
        @executable_path = executable_path
      end

      def run(record, arguments, timeout: 30)
        marker = "EMPEIRA_GUEST_EXIT_#{SecureRandom.hex(16)}"
        command = "#{Shellwords.join(['sudo', '-n', *arguments])}; empeira_guest_status=$?; " \
                  "printf '\\n#{marker}:%s\\n' \"$empeira_guest_status\" >&2; exit 0"
        result = @runner.run(binary('ssh'), arguments: [*options(record), 'empeira@127.0.0.1', command],
                                            timeout: timeout)
        command_result(result, marker, arguments.first)
      end

      def stream(record, arguments)
        command = Shellwords.join(['sudo', '-n', *arguments])
        @runner.stream(binary('ssh'), arguments: [*options(record), 'empeira@127.0.0.1', command])
      end

      def copy_to(record, source, destination, mode: '0644')
        temporary = "/home/empeira/.empeira-copy-#{SecureRandom.hex(8)}"
        transfer = @runner.run(binary('scp'), arguments: [*scp_options(record), source.to_s,
                                                          "empeira@127.0.0.1:#{temporary}"], timeout: 30)
        verify_result!(transfer, 'Cannot copy a file into the VM', 'scp')

        installed = run(record, ['install', '-m', mode, temporary, destination])
        verify_result!(installed, 'Cannot install a file in the VM', 'install')
      ensure
        if temporary
          cleanup = run(record, ['rm', '-f', '--', temporary])
          verify_result!(cleanup, 'Cannot verify VM upload staging cleanup; VM retained for diagnosis', 'rm')
        end
      end

      def wait(record, progress: nil, seconds: 300)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          begin
            result = run(record, ['cloud-init', 'status', '--wait'], timeout: 20)
            return if result.success?

            details = Execution::Diagnostics.command(result, operation: 'VM cloud-init readiness', tool: 'cloud-init')
          rescue TransportError => e
            raise unless e.transient? || e.timed_out

            details = e.message
          end

          raise Error, "VM SSH or cloud-init did not become ready; inspect serial log\n#{details}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          progress&.heartbeat('Waiting for VM network and cloud-init...')
          sleep 2
        end
      end

      private

      def command_result(result, marker, operation)
        raise transport_error(result, operation), cause: nil unless result.success?

        completion = completion_status(result, marker, operation)
        status = completion[1].to_i
        stderr = result.stderr.delete_suffix(completion[0])
        stderr = "SSH transport completed; guest command failed (exit=#{status})\n#{stderr}" unless status.zero?
        result.with(stderr: stderr, exit_status: status)
      end

      def completion_status(result, marker, operation)
        completion = /\n#{Regexp.escape(marker)}:(\d{1,3})\n\z/.match(result.stderr)
        unless completion && completion[1].to_i <= 255
          diagnostic = Execution::Diagnostics.command(result, operation: "VM guest #{operation}", tool: 'ssh')
          raise Error, "SSH guest completion status is unavailable; command outcome is unknown\n#{diagnostic}",
                cause: nil
        end

        completion
      end

      def transport_error(result, operation)
        transient = result.exit_status == 255 && !result.timed_out &&
                    result.stderr.match?(/connection (?:reset|closed|refused|timed out)|broken pipe/i) &&
                    !result.stderr.match?(/permission denied|host key|host identification|authentication/i)
        details = Execution::Diagnostics.command(result, operation: "VM guest #{operation}", tool: 'ssh')
        TransportError.new("SSH transport failed; guest command completion is unknown\n#{details}",
                           transient: transient, timed_out: result.timed_out)
      end

      def verify_result!(result, operation, tool)
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: operation, tool: tool)
        raise Error, "#{operation}\n#{details}", cause: nil
      end

      def client(record)
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'))
        backend = Network::Peer::Backend.build(context: @context, runner: @runner, runtime: nil, store: nil)
        Node::SSHClient.new(runner: @runner, credentials: credentials, user: 'empeira',
                            proxy_command: backend.ssh_command(record))
      end

      def options(record)
        client(record).options(record)
      end

      def scp_options(record)
        options(record).tap { |list| list[list.index('-p')] = '-P' }
      end

      def binary(name)
        @executable_path.split(File::PATH_SEPARATOR).each do |directory|
          path = Pathname(directory).join(name)
          return path.to_s if path.file? && path.executable?
        end
        raise UnavailableFeature, "#{name} is required for VM guest access"
      end
    end
  end
end
