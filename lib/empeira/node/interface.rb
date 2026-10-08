# frozen_string_literal: true

module Empeira
  module Node
    class Interface < Providers::Lifecycle
      attr_reader :backend

      def initialize(backend:, **dependencies)
        super(**dependencies)
        @backend = backend
      end

      def run(request)
        super(name: request.hostname, request: request)
      end
    end
  end
end
