# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class Attachment
        def initialize(backend:, record:, state:)
          @backend = backend
          @record = record
          @state = state
        end

        def arguments
          @backend.arguments(@record)
        end

        def launch(executable, arguments)
          @backend.launch(executable, arguments)
        end

        def connect
          @backend.connect(@record, @state)
        end
      end
    end
  end
end
