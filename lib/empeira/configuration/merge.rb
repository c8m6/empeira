# frozen_string_literal: true

module Empeira
  module Configuration
    module Merge
      module_function

      def call(lower, higher, path: [])
        lower = ImageSchema.override_base(lower, higher) if path.first == 'images' && path.size == 2
        copy(lower).merge(copy(higher)) do |key, old, replacement|
          old.is_a?(Hash) && replacement.is_a?(Hash) ? call(old, replacement, path: path + [key]) : replacement
        end
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, child| [copy(key), copy(child)] }
        when Array then value.map { |child| copy(child) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
