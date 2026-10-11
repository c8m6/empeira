# frozen_string_literal: true

module Empeira
  module Execution
    module Terminal
      CLEAN_EXIT_SIGNALS = %w[QUIT TSTP].map { |signal| Signal.list.fetch(signal) }.freeze

      # rubocop:disable-next Metrics/AbcSize -- Signal status and restored handlers share the session cleanup boundary.
      def self.with_interrupts
        return yield unless Thread.current == Thread.main

        previous = %w[TERM HUP QUIT TSTP].to_h do |signal|
          [signal, Signal.trap(signal) { raise SignalException, signal }]
        end
        yield
      rescue SignalException => e
        raise unless CLEAN_EXIT_SIGNALS.include?(e.signo)

        # Preserve the signal status after cleanup without a core dump or a suspended raw terminal.
        raise SystemExit, 128 + e.signo
      ensure
        previous&.each { |signal, handler| Signal.trap(signal, handler) }
      end

      def self.interactive?(output: $stdout, error: $stderr, environment: ENV)
        [output, error].all? { |io| io.respond_to?(:tty?) && io.tty? } &&
          environment['TERM'].to_s.downcase != 'dumb' && environment['CI'].to_s.empty?
      end

      def self.color?(**options)
        interactive?(**options) && options.fetch(:environment, ENV)['NO_COLOR'].to_s.empty?
      end
    end
  end
end
