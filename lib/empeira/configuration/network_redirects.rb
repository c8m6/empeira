# frozen_string_literal: true

module Empeira
  module Configuration
    class NetworkRedirects
      UNROUTABLE = %w[0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/3].map { |value| IPAddr.new(value) }.freeze

      def self.validate!(entries, path)
        raise ConfigurationError, "#{path} must be an array" unless entries.is_a?(Array)

        sources = entries.each_with_index.map do |entry, index|
          location = "#{path}[#{index}]"
          mapping!(entry, %w[from to], location)
          source!(entry.fetch('from'), "#{location}.from")
          target!(entry.fetch('to'), "#{location}.to")
          entry.fetch('from')
        end
        raise ConfigurationError, "#{path} contains duplicate source IP/port pairs" unless sources.uniq == sources
      end

      def self.mapping!(value, keys, path)
        return if value.is_a?(Hash) && value.keys.sort == keys.sort

        raise ConfigurationError, "#{path} requires only #{keys.join(' and ')}"
      end

      def self.source!(value, path)
        mapping!(value, %w[ip port], path)
        Network::DirectEgress.validate_ip!(value.fetch('ip'), path)
        if UNROUTABLE.any? { |range| range.include?(value.fetch('ip')) }
          raise ConfigurationError, "#{path}.ip must be a routable unicast IPv4 address"
        end

        port!(value.fetch('port'), "#{path}.port")
      end

      def self.target!(value, path)
        mapping!(value, %w[service port], path)
        service = value.fetch('service')
        unless service.is_a?(String) && service.match?(/\A#{Network::DirectEgress::DNS_LABEL}\z/)
          raise ConfigurationError, "#{path}.service must be an internal service name"
        end

        port!(value.fetch('port'), "#{path}.port")
      end

      def self.port!(value, path)
        return if value.is_a?(Integer) && value.between?(1, 65_535)

        raise ConfigurationError, "#{path} must be an integer TCP port from 1 through 65535"
      end
    end
  end
end
