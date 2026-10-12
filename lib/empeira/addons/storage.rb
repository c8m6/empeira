# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require 'digest'

module Empeira
  module Addons
    class Storage
      COMMIT = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
      attr_reader :root, :source_key

      def initialize(base:, source:, ref:)
        @base = Pathname(base)
        @source_key = Digest::SHA256.hexdigest(source)
        @root = @base.join(source_key)
        @reference = root.join('refs', Digest::SHA256.hexdigest(ref))
      end

      def installed
        return unless @reference.exist?

        directories.each { |directory| owned!(directory, directory: true) }
        owned!(@reference)
        commit = @reference.read.strip
        raise Empeira::Error, 'Installation reference is incomplete' unless commit.match?(COMMIT)

        path = revision(commit)
        owned!(path, directory: true)
        [commit, path]
      end

      def revision(commit)
        root.join('revisions', commit)
      end

      def synchronize
        prepare
        File.open(root.join('lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
          owned!(root.join('lock'))
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end

      def publish(commit)
        Tempfile.create('.reference-', @reference.dirname) do |file|
          file.write("#{commit}\n")
          file.flush
          file.fsync
          File.rename(file.path, @reference)
        end
      end

      def stage
        directory = Pathname(Dir.mktmpdir('.staging-', root))
        yield directory
      ensure
        FileUtils.remove_entry(directory) if directory&.exist?
      end

      def mirror
        root.join("#{source_key}.git")
      end

      private

      def prepare
        FileUtils.mkdir_p(@base.dirname, mode: 0o700)
        directories.each do |path|
          begin
            Dir.mkdir(path, 0o700)
          rescue Errno::EEXIST
            # Stable private directories, following the existing agent cache convention.
          end
          owned!(path, directory: true)
        end
      end

      def directories
        [@base, root, root.join('refs'), root.join('revisions')]
      end

      def owned!(path, directory: false)
        stat = path.lstat
        valid = stat.uid == Process.uid && !stat.symlink? && stat.mode.nobits?(0o077)
        valid &&= directory ? stat.directory? : stat.file? && stat.nlink == 1
        raise Empeira::Error, 'Addon cache contains an unsafe, missing or foreign entry' unless valid
      end
    end
  end
end
