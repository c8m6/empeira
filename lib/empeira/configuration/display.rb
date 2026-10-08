# frozen_string_literal: true

module Empeira
  module Configuration
    module Display
      SENSITIVE = /password|secret|token|credential|authorization|private.?key/i

      module_function

      def redact(value)
        case value
        when Hash
          value.to_h { |key, child| [key, key.to_s.match?(SENSITIVE) ? '[REDACTED]' : redact(child)] }
        when Array then value.map { |child| redact(child) }
        else value
        end
      end
    end
  end
end
