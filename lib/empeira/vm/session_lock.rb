# frozen_string_literal: true

module Empeira
  module VM
    # Pin one node instance during access without retaining the workspace mutation lock.
    class SessionLock
      def initialize(context:, record:)
        directory = context.locations.workspace(context.workspace)
        @path = directory.join("vm-session-#{record.fetch('peer').fetch('token')}.lock")
      end

      def acquire(shared:)
        lock = open_lock
        mode = shared ? File::LOCK_SH : File::LOCK_EX
        unless lock.flock(mode | File::LOCK_NB)
          raise Infrastructure::Locked, 'VM instance has active access or lifecycle operations; detach and retry'
        end

        lock.close_on_exec = true
        acquired = true
        lock
      ensure
        lock&.close unless acquired
      end

      def exclusive
        lock = acquire(shared: false)
        yield
      ensure
        lock&.close
      end

      private

      def open_lock
        raise Providers::OwnershipError, 'VM session lock path is unsafe' if @path.dirname.symlink? || @path.symlink?

        # A successful open passes descriptor ownership to acquire.
        # rubocop:disable-next Style/FileOpen
        lock = File.open(@path, File::RDWR | File::CREAT, 0o600)
        verify_lock!(lock.stat)

        opened = true
        lock
      ensure
        lock&.close unless opened
      end

      def verify_lock!(metadata)
        return if metadata.file? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise Providers::OwnershipError, 'VM session lock ownership is invalid'
      end
    end
  end
end
