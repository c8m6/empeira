# frozen_string_literal: true

module Empeira
  module VM
    # A guest controlling PTY with local raw-mode restoration; no login or input logging.
    class GuestShell
      def initialize(input:, output:)
        @input = input
        @output = output
      end

      def consume(channel)
        raise Error, 'Node shell requires a local input and output terminal' unless @input.tty? && @output.tty?

        @channel = channel
        previous = Signal.trap('WINCH') { @resized = true } if Thread.current == Thread.main
        channel.send_frame('type' => 'shell', 'size' => @input.winsize, 'term' => ENV.fetch('TERM', 'xterm'))
        Execution::Terminal.with_interrupts { @input.raw { exchange } }
      ensure
        Signal.trap('WINCH', previous) if previous
      end

      private

      def exchange
        @keyboard = @input
        loop do
          resize
          sources = readable_sources
          if sources.include?(@channel.io) || @channel.readable?
            result = consume_frame
            return result if result

            next
          end
          forward_input if @keyboard && sources.include?(@keyboard)
        end
      end

      def resize
        return unless @resized

        @channel.send_frame('type' => 'resize', 'size' => @input.winsize)
        @resized = false
      end

      def readable_sources
        keyboard = @credit ? @keyboard : nil
        IO.select([@channel.io, keyboard].compact, nil, nil, @channel.readable? ? 0 : 0.1)&.first || []
      end

      def forward_input
        bytes = @keyboard.read_nonblock(GuestChannel::CHUNK, exception: false)
        return if bytes == :wait_readable

        @channel.send_frame('type' => bytes ? 'input' : 'eof', 'data' => Base64.strict_encode64(bytes || ''))
        @credit = false
        @keyboard = nil unless bytes
      end

      def consume_frame
        frame = @channel.receive(timeout: 5)
        case frame['type']
        when 'started' then nil
        when 'ready'
          @credit = true
          nil
        when 'stdout'
          @output.write(Base64.strict_decode64(frame.fetch('data')))
          @output.flush
          nil
        when 'exit'
          GuestOutput.new.consume_completion(frame)
        else raise Error, 'VM shell returned an unexpected protocol message'
        end
      end
    end
  end
end
