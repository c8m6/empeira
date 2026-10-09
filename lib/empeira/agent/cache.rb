# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require 'pathname'
require 'tmpdir'
require 'tempfile'

module Empeira
  module Agent
    class CacheCorruption < Error; end

    class Cache
      include CacheStorage

      def initialize(root:, temporary: Dir.tmpdir)
        @root = Pathname(root)
        @temporary = temporary
      end

      def with_artifact(request, enabled:, acquire:, pin: nil, &use)
        return temporary(request, pin, acquire, &use) unless enabled

        prepare
        key = fingerprint(request)
        lock(key) do
          artifact = load(key, request, pin) || acquire_cached(key, request, pin, acquire)
          use.call(artifact)
        end
      rescue SystemCallError, IOError
        raise Error, 'Cannot read or write the private agent cache; check ownership and permissions', cause: nil
      end

      def self.fingerprint(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def self.canonical(value)
        return value.sort.to_h.transform_values { |child| canonical(child) } if value.is_a?(Hash)
        return value.map { |child| canonical(child) } if value.is_a?(Array)

        value
      end

      private

      def fingerprint(value)
        self.class.fingerprint(value)
      end

      def temporary(request, pin, acquire)
        Dir.mktmpdir('empeira-agent-', @temporary) do |directory|
          artifact = acquire.call(directory)
          validate!(artifact, request, pin)
          yield artifact
        end
      end

      def acquire_cached(key, request, pin, acquire)
        Dir.mktmpdir('.download-', @root.join('entries')) do |directory|
          artifact = acquire.call(directory)
          validate!(artifact, request, pin)
          publish(key, artifact, request)
        end
      end

      def load(key, request, pin)
        reference = @root.join('refs', "#{key}.json")
        return unless reference.exist? || reference.symlink?

        owned!(reference)
        artifact = read_artifact(reference, request)
        validate!(artifact, request, pin)
        artifact
      rescue JSON::ParserError, KeyError, Errno::ENOENT, CacheCorruption
        reference.delete if reference.exist?
        nil
      end

      def read_artifact(reference, request)
        entry = read_entry(reference)
        directory = @root.join('entries', entry)
        owned!(directory, directory: true)
        metadata = directory.join('metadata.json')
        owned!(metadata)
        path = directory.join("package.#{request.fetch('format')}")
        owned!(path)
        Artifact.new(path: path, metadata: JSON.parse(metadata.read))
      end

      def read_entry(reference)
        data = JSON.parse(reference.read)
        raise CacheCorruption, 'Invalid agent cache reference' unless data.is_a?(Hash)

        entry = data.fetch('entry')
        unless entry.is_a?(String) && entry.match?(/\A[a-f0-9]{64}\z/)
          raise CacheCorruption,
                'Invalid agent cache reference'
        end

        entry
      end

      def validate!(artifact, request, pin)
        metadata = artifact.metadata
        valid = artifact.valid_identity?(request) && valid_file?(artifact, request.fetch('format'))
        valid &&= metadata['sha256'] == pin if pin
        raise CacheCorruption, 'Agent cache artifact or package identity is damaged' unless valid
      end

      def valid_file?(artifact, format)
        path = artifact.path
        return false unless path.file? && path.size.positive? && path.size == artifact.metadata['size']
        return false unless Digest::SHA256.file(path).hexdigest == artifact.metadata['sha256']

        magic = File.binread(path, 8)
        format == 'deb' ? magic == "!<arch>\n" : magic.start_with?("\xed\xab\xee\xdb".b)
      end
    end
  end
end
