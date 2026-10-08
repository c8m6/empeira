# frozen_string_literal: true

require 'io/console'

module Empeira
  module CLI
    # The cursor stays on the second row while a workflow is active.
    class ProgressDisplay
      DEFAULT_COLUMNS = 80
      MIN_BAR_COLUMNS = 4

      def initialize(io:, columns: nil)
        @io = io
        @columns = columns
        @drawn = false
      end

      def render(event, waiting: false)
        return finish unless event.state == :active

        available = [terminal_columns - 1, 0].max
        message = ProgressRenderer.clean_message(event.message)
        message += waiting == true ? ' (still working)' : " (still working #{waiting})" if waiting
        @io.print("\r\e[1A") if @drawn
        @io.print("\r\e[2K", progress_line(event.percent, available), "\n\r\e[2K", truncate(message, available))
        @drawn = true
        @io.flush
      end

      def finish
        return unless @drawn

        @io.print("\r\e[2K\e[1A\r\e[2K")
        @io.flush
        @drawn = false
      end

      private

      def progress_line(percent, available)
        label = format('%3d%%', percent)
        bar_width = available - label.length - 3
        if bar_width < MIN_BAR_COLUMNS
          compact = "[#{percent}%]"
          compact = "#{percent}%" if compact.length > available
          return compact.length <= available ? compact : ''
        end

        filled = (bar_width * percent / 100.0).round
        "[#{'█' * filled}#{'-' * (bar_width - filled)}] #{label}"
      end

      def truncate(message, available)
        return '' if available.zero?
        return message if message.bytesize <= available

        suffix = available >= 4 ? '...' : ''
        budget = available - suffix.length
        result = +''
        message.each_grapheme_cluster do |cluster|
          break if result.bytesize + cluster.bytesize > budget

          result << cluster
        end
        result << suffix
      end

      def terminal_columns
        value = @columns ? @columns.call : @io.winsize.last
        value.is_a?(Integer) && value.positive? ? value : DEFAULT_COLUMNS
      rescue IOError, SystemCallError, NoMethodError
        DEFAULT_COLUMNS
      end
    end

    class ProgressRenderer
      SPINNER = ['|', '/', '-', '\\'].freeze
      SPINNER_INTERVAL = 0.25

      def self.clean_message(message)
        message.to_s.scrub.gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/, ' ')
      end

      def initialize(io: $stderr, interactive: nil, columns: nil, heartbeat_interval: 10, clock: nil)
        @io = io
        active = interactive.nil? ? interactive_output? : interactive
        @display = ProgressDisplay.new(io: io, columns: columns) if active
        @heartbeat_interval = heartbeat_interval
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @spinner = 0
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def call(event)
        @mutex.synchronize do
          @io.print("\n") if @event&.state == :suspended && event.state == :failed
          @event = event
          @spinner = 0
          @next_tick = @clock.call + @heartbeat_interval
          render_state(event)
          @condition.signal
        end
      end

      def during
        @finished = false
        heartbeat = Thread.new { heartbeat_loop }
        yield
      ensure
        if heartbeat
          @mutex.synchronize do
            @finished = true
            @condition.signal
          end
          heartbeat.join
        end
        @mutex.synchronize { @display&.finish }
      end

      private

      def render_state(event)
        if event.state == :warning
          @display&.finish
          @io.puts(self.class.clean_message(event.message))
          @io.flush
        elsif %i[suspended resumed].include?(event.state)
          @display&.finish
          @io.print("\n") if event.state == :resumed
        else
          render(event)
        end
      end

      def interactive_output?
        Execution::Terminal.interactive?(error: @io)
      end

      def heartbeat_loop
        @mutex.synchronize do
          until @finished
            tick
            delay = @event&.state == :active ? [@next_tick - @clock.call, 0].max : nil
            @condition.wait(@mutex, delay) unless @finished
          end
        end
      end

      def tick
        return unless @event&.state == :active && @clock.call >= @next_tick

        render(@event, waiting: @display ? SPINNER[@spinner % SPINNER.size] : true)
        @spinner += 1
        @next_tick = @clock.call + (@display ? SPINNER_INTERVAL : @heartbeat_interval)
      end

      def render(event, waiting: false)
        return @display.render(event, waiting: waiting) if @display

        message = self.class.clean_message(event.message)
        text = format('[%<percent>3d%%] %<message>s%<wait>s', percent: event.percent, message: message,
                                                              wait: waiting ? ' (still working)' : '')
        @io.puts(text)
        @io.flush
      end
    end
  end
end
