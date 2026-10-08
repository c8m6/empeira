# frozen_string_literal: true

# rubocop:disable Lint/UnusedMethodArgument -- Preserve explicit adapter keyword contracts.

module Empeira
  module Network
    class UnsupportedPolicy < Error; end

    Policy = Data.define do
      def require_support!(isolated:, controlled_egress:)
        raise UnsupportedPolicy, 'Isolated networking is required' unless isolated == true
      end
    end

    class Interface
      def initialize(context:, runner:)
        @context = context
        @runner = runner
      end

      def provision(policy:)
        policy.require_support!(**capabilities)
        create(policy: policy)
      end

      protected

      def capabilities
        { isolated: false, controlled_egress: false }
      end

      def create(policy:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end
    end
  end
end

# rubocop:enable Lint/UnusedMethodArgument
