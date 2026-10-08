# frozen_string_literal: true

require 'io/wait'

module Empeira
  module Network
    module Peer
      class ChannelServer
        def initialize(path, runner: Execution::Runner.new)
          @directory = Pathname(path).dirname
          @config = JSON.parse(File.read(path))
          @runner = runner
        end

        def run
          File.umask(0o077)
          control = @directory.join('control.sock')
          @listener = UNIXServer.new(control)
          File.chmod(0o600, control)
          File.write(@directory.join('channel.pid'), Process.pid.to_s, mode: 'w', perm: 0o600)
          @connection = UNIXSocket.new(@directory.join('ethernet.sock'))
          @worker = Thread.new { forward }
          serve
        ensure
          cleanup
        end

        private

        def cleanup
          begin
            @connection&.shutdown
          rescue StandardError
            nil
          end
          @worker.kill.join if @worker && !@worker.join(10)
          @listener&.close
          FileUtils.rm_f(@directory.join('control.sock'))
          FileUtils.rm_f(@directory.join('channel.pid'))
        end

        def forward
          File.open(@directory.join('channel.log'), 'w', 0o600) do |log|
            command = @config.fetch('command')
            @result = @runner.stream(command.first, arguments: command.drop(1),
                                                    input: @connection, output: @connection, error: log)
          end
        end

        def serve
          loop do
            break unless @worker.alive?
            next unless @listener.wait_readable(0.2)

            client = @listener.accept
            begin
              message = JSON.parse(client.gets(4096))
              next unless message['token'] == @config.fetch('token')

              client.puts(JSON.generate('token' => @config.fetch('token'), 'running' => @worker.alive?))
              stop = message['operation'] == 'stop'
            ensure
              client.close
            end
            break if stop
          end
        end
      end
    end
  end
end
