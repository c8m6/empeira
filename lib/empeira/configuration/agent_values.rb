# frozen_string_literal: true

module Empeira
  module Configuration
    # Scalar validation shared by fragments and resolved agent sources.
    module AgentValues
      def required!(data, keys, path)
        keys.each { |key| raise ConfigurationError, "#{path}.#{key} is required" unless data.key?(key) }
      end

      def package_token!(value, path)
        return if value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.+-]*\z/)

        raise ConfigurationError, "#{path} must be a package name"
      end

      def token!(value, path)
        return if value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.+:~-]*\z/)

        raise ConfigurationError, "#{path} must be a package/version token"
      end

      def suffix!(value, path)
        return if value.is_a?(String) && value.match?(/\A[-+a-zA-Z0-9.]+\z/)

        raise ConfigurationError, "#{path} is invalid"
      end

      def digest!(value, path)
        return if value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)

        raise ConfigurationError, "#{path} must be a SHA-256 digest"
      end

      def boolean!(value, path)
        raise ConfigurationError, "#{path} must be boolean" unless [true, false].include?(value)
      end

      def https_url!(value, path)
        uri = URI(value)
        return if https_endpoint?(uri) && !value.match?(/[\s\x00-\x1f\x7f]/)

        raise ConfigurationError, "#{path} must be a credential-free HTTPS URL"
      rescue URI::InvalidURIError, TypeError
        raise ConfigurationError, "#{path} must be a credential-free HTTPS URL"
      end

      def https_endpoint?(uri)
        uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil?
      end
    end
  end
end
