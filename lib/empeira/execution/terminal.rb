# frozen_string_literal: true

module Empeira
  module Execution
    module Terminal
      def self.with_interrupts
        return yield unless Thread.current == Thread.main

        previous = Signal.trap('TERM') { raise SignalException, 'TERM' }
        yield
      ensure
        Signal.trap('TERM', previous) if previous
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
