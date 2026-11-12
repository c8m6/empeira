# frozen_string_literal: true

module Empeira
  module Infrastructure
    # Pin one node instance during access without retaining the workspace mutation lock.
    class SessionLock
      def initialize(path:, subject:)
        @path = path
        @subject = subject
      end

      def acquire(shared:)
        lock = open_lock
        mode = shared ? File::LOCK_SH : File::LOCK_EX
        unless lock.flock(mode | File::LOCK_NB)
          raise Infrastructure::Locked,
                "#{@subject} instance has active access or lifecycle operations; detach and retry"
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
        if @path.dirname.symlink? || @path.symlink?
          raise Providers::OwnershipError,
                "#{@subject} session lock path is unsafe"
        end

        # A successful open passes descriptor ownership to acquire.
        # rubocop:disable-next Style/FileOpen
        lock = File.open(@path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
        verify_lock!(lock.stat)

        opened = true
        lock
      ensure
        lock&.close unless opened
      end

      def verify_lock!(metadata)
        return if metadata.file? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise Providers::OwnershipError, "#{@subject} session lock ownership is invalid"
      end
    end
  end
end
