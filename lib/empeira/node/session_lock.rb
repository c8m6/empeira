# frozen_string_literal: true

require 'digest'

module Empeira
  module Node
    # Native container IDs pin access to an observed instance, never just its reusable name.
    class SessionLock < Infrastructure::SessionLock
      def initialize(context:, record:)
        id = record.fetch('id')
        raise Providers::OwnershipError, 'Container session requires a recorded instance ID' unless
          id.is_a?(String) && !id.empty?

        directory = context.locations.workspace(context.workspace)
        super(path: directory.join("container-session-#{Digest::SHA256.hexdigest(id)}.lock"), subject: 'Container')
      end
    end
  end
end
