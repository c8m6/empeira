# frozen_string_literal: true

module Empeira
  module Addons
    class Error < Empeira::Error
      attr_reader :exit_status

      def initialize(name, message, exit_status: 1)
        @exit_status = exit_status
        super("Addon #{name}: #{message}")
      end
    end
  end
end
