# frozen_string_literal: true

require 'digest'
require 'json'

module Empeira
  module Images
    class Identity
      attr_reader :cache_key, :distribution, :version, :architecture, :source, :revision, :checksum

      def to_h
        { 'distribution' => distribution, 'version' => version, 'architecture' => architecture,
          'source' => source, 'revision' => revision, 'checksum' => checksum }
      end

      # rubocop:disable-next Metrics/AbcSize -- All fields participate in the immutable identity.
      def initialize(distribution:, version:, architecture:, source:, revision:, checksum:)
        fields = [distribution, version, architecture, source, revision, checksum]
        unless fields.all? { |value| value.is_a?(String) && !value.strip.empty? }
          raise Error, 'Image identity fields must be non-empty strings'
        end
        raise Error, 'Image checksum must be a SHA-256 hex digest' unless checksum.match?(/\A[0-9a-f]{64}\z/i)

        @distribution, @version, @architecture, @source, @revision, @checksum = fields
        @cache_key = Digest::SHA256.hexdigest(JSON.generate(fields[0...-1] + [checksum.downcase])).freeze
        freeze
      end
    end
  end
end
