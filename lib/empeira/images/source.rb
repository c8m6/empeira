# frozen_string_literal: true

# rubocop:disable Lint/UnusedMethodArgument -- Preserve explicit adapter keyword contracts.

module Empeira
  module Images
    class Source
      def resolve(identity:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end

      def fetch(identity:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end
    end
  end
end

# rubocop:enable Lint/UnusedMethodArgument
