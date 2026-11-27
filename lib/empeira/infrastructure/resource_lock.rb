# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'

module Empeira
  module Infrastructure
    # Only a particular shared resource or an inventory transaction owns this lock.
    class ResourceLock
      def initialize(directory:, resource:, filename: nil)
        @directory = Pathname(directory)
        @path = @directory.join(filename || "#{Digest::SHA256.hexdigest(resource)}.lock")
      end

      def synchronize(&block)
        held = Thread.current[:empeira_resource_locks] ||= {}
        key = @path.to_s
        return yield if held[key] == Process.pid

        prepare_directory
        File.open(@path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
          verify_file!(file.stat)
          file.close_on_exec = true
          locked(file, held, key, &block)
        end
      end

      private

      def locked(file, held, key)
        file.flock(File::LOCK_EX)
        held[key] = Process.pid
        yield
      ensure
        held.delete(key)
        file.flock(File::LOCK_UN)
      end

      def prepare_directory
        raise StateError, 'Resource lock directory is an unsafe symlink' if @directory.symlink?

        FileUtils.mkdir_p(@directory, mode: 0o700)
        metadata = @directory.lstat
        return if metadata.directory? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise StateError, 'Resource lock directory ownership is invalid'
      end

      def verify_file!(metadata)
        return if metadata.file? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise StateError, 'Resource lock ownership is invalid'
      end
    end
  end
end
