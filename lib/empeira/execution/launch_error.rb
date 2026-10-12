# frozen_string_literal: true

module Empeira
  module Execution
    class LaunchError < ExecutionError
      attr_reader :exit_status

      def initialize(message, exit_status:)
        @exit_status = exit_status
        super(message)
      end
    end
  end
end
