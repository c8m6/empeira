# frozen_string_literal: true

module Empeira
  module Configuration
    class ImageSchema
      PATTERNS = {
        'repository' => Images::Configuration::REPOSITORY, 'tag' => Images::Configuration::TAG,
        'digest' => Images::Configuration::DIGEST, 'build' => %r{\A[a-zA-Z0-9_/-]+/Containerfile\z}
      }.freeze

      def self.validate!(value, path, effective: false)
        raise ConfigurationError, "#{path} must be an image mapping" unless value.is_a?(Hash)

        value.each do |key, item|
          raise ConfigurationError, "#{path}.#{key} is invalid or unsupported" unless valid_field?(key, item)
        end
        validate_combination!(value, path) if effective || value.key?('reference')
      end

      def self.valid_field?(key, item)
        return reference?(item) if key == 'reference'

        item.is_a?(String) && PATTERNS.key?(key) && item.match?(PATTERNS[key])
      end

      def self.reference?(value)
        return false unless value.is_a?(String)

        repository, digest = value.split('@', 2)
        if digest
          return repository.match?(Images::Configuration::REPOSITORY) && digest.match?(Images::Configuration::DIGEST)
        end

        repository, _, tag = value.rpartition(':')
        repository.match?(Images::Configuration::REPOSITORY) && tag.match?(Images::Configuration::TAG)
      end

      def self.validate_combination!(value, path)
        return validate_reference!(value, path) if value['reference']

        if value['build']
          raise ConfigurationError, "#{path}.build cannot be combined with an image reference" if value.keys.size > 1

          return
        end
        return if value['repository'] && (value['tag'] || value['digest'])

        raise ConfigurationError, "#{path} requires repository and tag/digest, reference, or build"
      end

      def self.validate_reference!(value, path)
        return if value.keys.size == 1

        raise ConfigurationError, "#{path}.reference cannot be combined with repository, tag, digest or build"
      end

      # Explicit image selections replace inherited pins; a tag alongside an explicit digest is descriptive.
      def self.override_base(lower, higher)
        return {} if higher.key?('reference') || higher.key?('build')
        return lower unless higher.keys.intersect?(%w[repository tag digest])

        value = lower.except('reference', 'build')
        value.delete('digest') if !higher.key?('digest') && higher.keys.intersect?(%w[repository tag])
        value
      end
    end
  end
end
