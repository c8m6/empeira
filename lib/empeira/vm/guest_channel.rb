# frozen_string_literal: true

require 'base64'
require 'securerandom'
require 'io/wait'

module Empeira
  module VM
    # One private, instance-bound VirtIO-Serial session; never logs protocol payloads.
    class GuestChannel
      LIMIT = 131_072
      CHUNK = 16_384

      def initialize(record:, qemu:)
        @record = record
        @qemu = qemu
        @id = SecureRandom.hex(16)
        @buffer = +''.b
      end

      def open
        @qemu.with_management_socket(@record) do |path, expected|
          connect(path, expected) { yield self }
        end
      end

      def connect(path, expected)
        original = path.lstat
        @socket = UNIXSocket.new(path)
        current = path.lstat
        unless [original.dev, original.ino] == [current.dev, current.ino] &&
               expected == { 'device' => current.dev, 'inode' => current.ino }
          raise Providers::OwnershipError, 'VM management socket changed while connecting'
        end

        handshake!

        yield self
      ensure
        @socket&.close
      end

      def readable?
        @buffer.include?("\n")
      end

      def io
        @socket
      end

      def handshake!
        send_frame('type' => 'hello', 'token' => @record.fetch('peer').fetch('token'))
        response = receive(timeout: 5)
        unless response['type'] == 'hello' && response['version'] == Management::VERSION &&
               response['token'] == @record.fetch('peer').fetch('token')
          raise Providers::OwnershipError, 'VM management identity mismatch; operation refused'
        end
      end

      def send_frame(frame)
        message = "#{JSON.generate(frame.merge('id' => @id))}\n"
        raise Error, 'VM management request is too large' if message.bytesize > LIMIT

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until message.empty?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Timeout::Error if remaining <= 0 || !@socket.wait_writable(remaining)

          written = @socket.write_nonblock(message, exception: false)
          message = message.byteslice(written..) unless written == :wait_writable
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Frame size, deadline and session identity are checked together.
      def receive(timeout:)
        deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
        until @buffer.include?("\n")
          remaining = deadline && (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          raise Timeout::Error if (remaining && remaining <= 0) || !@socket.wait_readable(remaining)

          @buffer << @socket.readpartial(CHUNK)
          raise Error, 'VM management response is oversized' if @buffer.bytesize > LIMIT
        end
        line, @buffer = @buffer.split("\n", 2)
        result = JSON.parse(line)
        unless result.is_a?(Hash) && result['id'] == @id
          raise Providers::OwnershipError, 'VM management response belongs to another operation'
        end

        result
      rescue JSON::ParserError
        raise Error, 'VM management returned malformed protocol data', cause: nil
      end

      def cancel
        send_frame('type' => 'cancel')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        loop do
          frame = receive(timeout: deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC))
          next unless frame['type'] == 'exit'

          GuestOutput.new.consume_completion(frame)
          break
        end
      rescue StandardError
        raise Guest::TransportError, 'VM guest session cancellation is unconfirmed; node retained', cause: nil
      end
    end
  end
end
