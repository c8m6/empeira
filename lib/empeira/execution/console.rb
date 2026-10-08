# frozen_string_literal: true

require 'io/console'
require 'socket'

module Empeira
  module Execution
    class Console
      def attach(path, input:, output:)
        UNIXSocket.open(path) do |socket|
          if input.tty?
            input.raw { transfer(socket, input, output) }
          else
            transfer(socket, input, output)
          end
        end
        Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      rescue SystemCallError, IOError
        raise ExecutionError, 'VM console connection failed or closed', cause: nil
      end

      def transfer(socket, input, output)
        loop do
          IO.select([socket, input]).first.each do |source|
            bytes = source.readpartial(4096)
            if source == socket
              output.write(bytes)
              output.flush
            else
              before, escape, = bytes.partition("\x1d")
              socket.write(before)
              return nil unless escape.empty?
            end
          end
        end
      rescue EOFError
        nil
      end
    end
  end
end
