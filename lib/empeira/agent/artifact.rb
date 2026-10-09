# frozen_string_literal: true

module Empeira
  module Agent
    Artifact = Data.define(:path, :metadata) do
      def valid_identity?(request)
        metadata.is_a?(Hash) && metadata['schema'] == 1 && metadata['request'] == request &&
          valid_version?(request) && valid_transport? && valid_keys? && valid_architecture?(request)
      end

      private

      def valid_version?(request)
        metadata['version'].is_a?(String) &&
          Versions.match?(metadata['version'], request.fetch('requested_version'), suffix: request['suffix'])
      end

      def valid_transport?
        uri = URI(metadata['url'])
        Configuration::AgentSchema.https_endpoint?(uri) &&
          %w[authenticated verify_signatures].all? { |key| [true, false].include?(metadata[key]) }
      rescue URI::InvalidURIError, TypeError, ArgumentError
        false
      end

      def valid_keys?
        keys = metadata['public_keys']
        keys.is_a?(Array) && keys.all? { |key| key.is_a?(String) && !Base64.strict_decode64(key).empty? }
      rescue ArgumentError
        false
      end

      def valid_architecture?(request)
        target = Target.new(os: request.fetch('distribution'), release: request.fetch('release'),
                            architecture: request.fetch('architecture'))
        generic = request.fetch('format') == 'deb' ? 'all' : 'noarch'
        [target.native_architecture, generic].include?(metadata['architecture'])
      end
    end
  end
end
