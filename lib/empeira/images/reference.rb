# frozen_string_literal: true

module Empeira
  module Images
    # Registry selection applies to repository fields, never exact reference overrides.
    module Reference
      HOST = /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]+)?\z/

      def self.hosted?(repository)
        first = repository.split('/').first
        first.include?('.') || first.include?(':') || first == 'localhost'
      end

      def self.registry?(value)
        return true if value.nil?
        return false unless value.is_a?(String) && value.match?(HOST) && hosted?(value)

        port = value.split(':', 2)[1]
        port.nil? || (1..65_535).cover?(port.to_i)
      end

      def self.repository(value, registry: nil)
        hosted?(value) ? value : "#{registry || 'docker.io'}/#{value}"
      end

      # Reserved recipe base declarations contain a tag or digest, not a YAML reference override.
      def self.base(value, registry: nil)
        path = value.split('@', 2).first.sub(%r{:[^/:]+\z}, '')
        repository(path, registry: registry) + value.delete_prefix(path)
      end

      def self.pinned(reference, digest)
        repository = reference.split('@').first.sub(%r{:[^/:]+\z}, '')
        "#{repository}@#{digest}"
      end

      def self.host(reference)
        first, path = reference.split('/', 2)
        path && registry?(first) ? first : 'docker.io'
      end
    end
  end
end
