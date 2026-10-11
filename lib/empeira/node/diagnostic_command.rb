# frozen_string_literal: true

module Empeira
  module Node
    module DiagnosticCommand
      def self.validate!(arguments, timeout)
        raise ConfigurationError, 'Provide a guest command and arguments after --' unless valid_arguments?(arguments)
        return if timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? && timeout <= 86_400)

        raise ConfigurationError, 'Command timeout must be positive and at most 86400 seconds'
      end

      def self.valid_arguments?(arguments)
        arguments.is_a?(Array) && !arguments.empty? && !arguments.first.to_s.empty? &&
          arguments.all? { |argument| argument.is_a?(String) && !argument.include?("\0") }
      end
    end
  end
end
