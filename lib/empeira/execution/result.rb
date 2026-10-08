# frozen_string_literal: true

module Empeira
  module Execution
    Result = Data.define(:stdout, :stderr, :exit_status, :timed_out) do
      def success?
        !timed_out && exit_status.is_a?(Integer) && exit_status.zero?
      end
    end
  end
end
