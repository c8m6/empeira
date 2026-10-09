# frozen_string_literal: true

module Empeira
  module Agent
    # Filesystem ownership, stable locks and atomic publication for the package cache.
    module CacheStorage
      private

      def prepare
        FileUtils.mkdir_p(@root.dirname, mode: 0o700)
        [@root, @root.join('entries'), @root.join('refs'), @root.join('locks')].each do |path|
          begin
            Dir.mkdir(path, 0o700)
          rescue Errno::EEXIST
            # Concurrent creation is allowed only after ownership verification.
          end
          owned!(path, directory: true)
        end
      end

      def owned!(path, directory: false)
        stat = path.lstat
        valid = stat.uid == Process.uid && !stat.symlink? && stat.mode.nobits?(0o077)
        valid &&= directory ? stat.directory? : stat.file? && stat.nlink == 1
        raise Error, 'Agent cache contains an unsafe or foreign entry; refusing access' unless valid
      end

      def lock(key)
        path = @root.join('locks', key)
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
          owned!(path)
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end

      def publish(key, artifact, request)
        entry = fingerprint(request.merge('native_version' => artifact.metadata.fetch('version')))
        metadata = artifact.metadata.merge('request' => request)
        final = commit_entry(entry, artifact, metadata, request)
        write_reference(key, entry)
        Artifact.new(path: final.join("package.#{request.fetch('format')}"), metadata: metadata)
      end

      def commit_entry(entry, artifact, metadata, request)
        staging = stage_entry(artifact, metadata, request)
        final = @root.join('entries', entry)
        remove_owned_entry(final) if final.exist?
        File.rename(staging, final)
        final
      end

      def stage_entry(artifact, metadata, request)
        staging = Pathname(File.dirname(artifact.path)).join('entry')
        Dir.mkdir(staging, 0o700)
        File.rename(artifact.path, staging.join("package.#{request.fetch('format')}"))
        File.write(staging.join('metadata.json'), JSON.generate(metadata), perm: 0o600)
        staging.children.each { |path| File.open(path, 'r+', &:fsync) }
        staging
      end

      def remove_owned_entry(directory)
        owned!(directory, directory: true)
        directory.children.each { |child| owned!(child) }
        FileUtils.remove_entry(directory)
      end

      def write_reference(key, entry)
        reference = @root.join('refs', "#{key}.json")
        Tempfile.create(['.ref-', '.json'], reference.dirname) do |file|
          file.chmod(0o600)
          file.write(JSON.generate('entry' => entry))
          file.flush
          file.fsync
          File.rename(file.path, reference)
        end
      end
    end
  end
end
