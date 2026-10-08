# frozen_string_literal: true

module Empeira
  module Modules
    # Only controlled worker records affect counts; ordinary tool output stays buffered.
    class Events
      attr_reader :name

      def initialize(progress:)
        @progress = progress
        @pending = +''.b
        @completed = []
      end

      def observe(chunk)
        @pending << chunk
        while (line = @pending.slice!(/.*?\n/m))
          event = line.match(/\AEMPEIRA_MODULE_(TOTAL|START|DONE):([a-z0-9_]+)\n\z/)
          receive(*event.captures) if event
        end
        @pending.clear if @pending.bytesize > 1024
      end

      def start(name)
        @name = name
        show
      end

      def finish!
        raise Error, 'Incomplete Puppetfile module progress protocol' unless @total == @completed.size
      end

      private

      def receive(kind, value)
        case kind
        when 'TOTAL' then total(value)
        when 'START' then start(value)
        when 'DONE' then done(value)
        end
      end

      def total(value)
        raise Error, 'Invalid Puppetfile module total' unless @total.nil? && value.match?(/\A\d+\z/)

        @total = Integer(value, 10)
        @name = 'Puppetfile modules'
        show
      end

      def done(name)
        unless name == @name && @total && @completed.size < @total && !@completed.include?(name)
          raise Error, 'Invalid Puppetfile module completion record'
        end

        @completed << name
        show
      end

      def show
        return @progress.heartbeat(@name) unless @total

        @progress.count(@completed.size, @total, "#{@name} (#{@completed.size}/#{@total})")
      end
    end
  end
end
