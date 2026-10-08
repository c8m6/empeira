# frozen_string_literal: true

module SharedNetworkProof
  # Only the central runner starts external processes. The private socket carries
  # QEMU Ethernet framing; SSH/runtime exec handles the machine boundary.
  class PacketChannel
    attr_reader :path, :command

    def initialize(directory:, name:, command:, runner: Empeira::Execution::Runner.new)
      @path = File.join(directory, "#{name}-ethernet.sock")
      @log_path = File.join(directory, "#{name}-transport.log")
      @command = command
      @runner = runner
    end

    def start
      @listener = UNIXServer.new(path)
      File.chmod(0o600, path)
      @thread = Thread.new do
        @connection = @listener.accept
        File.open(@log_path, 'w', 0o600) do |log|
          @result = @runner.stream(@command.first, arguments: @command.drop(1),
                                                   input: @connection, output: @connection, error: log)
        end
      rescue IOError, Errno::EBADF
        raise unless @stopping
      end
      self
    end

    def stop
      @stopping = true
      @connection&.close
      @listener&.close
      raise Failure, "Packet channel did not exit; logs: #{@log_path}" unless @thread&.join(10)

      FileUtils.rm_f(path)
      return if @result.nil? || @result.success?

      raise Failure, "Packet channel failed: #{File.read(@log_path).byteslice(0, 2000)}"
    end

    def stopped?
      !@thread&.alive?
    end
  end
end
