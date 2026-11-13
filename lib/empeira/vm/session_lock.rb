# frozen_string_literal: true

module Empeira
  module VM
    class SessionLock < Infrastructure::SessionLock
      def initialize(context:, record:)
        directory = context.locations.workspace(context.workspace)
        super(path: directory.join("vm-session-#{record.fetch('peer').fetch('token')}.lock"), subject: 'VM')
      end
    end
  end
end
