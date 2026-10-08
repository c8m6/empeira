# frozen_string_literal: true

module Empeira
  module Images
    # Only reviewed EMPEIRA_BASE_* ARG declarations are dependencies. This is not a Dockerfile parser.
    module Recipe
      BASE = /^ARG (EMPEIRA_BASE_[A-Z0-9_]+)=([^\s]+)$/

      def self.render(source, registry: nil)
        source.gsub(BASE) do
          name, value = Regexp.last_match.captures
          value = Reference.base(value, registry: registry) unless value.start_with?('@') || value == 'scratch'
          "ARG #{name}=#{value}"
        end
      end

      def self.bases(recipe)
        recipe.scan(BASE).to_h.reject { |_, value| value == 'scratch' }
      end
    end
  end
end
