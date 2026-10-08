# frozen_string_literal: true

module Empeira
  module Immutable
    module_function

    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, child|
          deep_freeze(key)
          deep_freeze(child)
        end
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
