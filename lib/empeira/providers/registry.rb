# frozen_string_literal: true

module Empeira
  module Providers
    class Registry
      def initialize(factories)
        @factories = factories.transform_keys(&:to_s).transform_values(&:freeze).freeze
        @names = @factories.keys.freeze
      end

      attr_reader :names

      def build(name, **dependencies)
        factory = @factories.fetch(name.to_s) do
          raise Error, "Unknown provider. Choose one of: #{names.join(', ')}"
        end
        factory.call(**dependencies)
      end
    end
  end
end
