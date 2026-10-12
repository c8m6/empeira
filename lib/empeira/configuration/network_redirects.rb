# frozen_string_literal: true

module Empeira
  module Configuration
    class NetworkRedirects
      UNROUTABLE = %w[0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/3].map { |value| IPAddr.new(value) }.freeze

      def self.validate!(entries, path)
        raise ConfigurationError, "#{path} must be an array" unless entries.is_a?(Array)

        sources = entries.each_with_index.map do |entry, index|
          validate_entry!(entry, "#{path}[#{index}]")
        end
        return if sources.uniq == sources

        raise ConfigurationError,
              "#{path} contains duplicate source IP/port/protocol tuples"
      end

      def self.validate_entry!(entry, path)
        mapping!(entry, %w[from to], path)
        source!(entry.fetch('from'), "#{path}.from")
        target!(entry.fetch('to'), "#{path}.to")
        source = entry.fetch('from')
        udp_target!(entry, path) if source.fetch('protocol', 'tcp') == 'udp'
        source.values_at('ip', 'port') + [source.fetch('protocol', 'tcp')]
      end

      def self.mapping!(value, keys, path)
        return if value.is_a?(Hash) && value.keys.sort == keys.sort

        raise ConfigurationError, "#{path} requires only #{keys.join(' and ')}"
      end

      def self.source!(value, path)
        mapping!(value.is_a?(Hash) ? value.except('protocol') : value, %w[ip port], path)
        unless %w[tcp udp].include?(value.fetch('protocol', 'tcp'))
          raise ConfigurationError, "#{path}.protocol must be tcp or udp (default: tcp)"
        end

        Network::DirectEgress.validate_ip!(value.fetch('ip'), path, allow_benchmark: true)
        if UNROUTABLE.any? { |range| range.include?(value.fetch('ip')) }
          raise ConfigurationError, "#{path}.ip must be a routable unicast IPv4 address"
        end

        port!(value.fetch('port'), "#{path}.port")
      end

      def self.udp_target!(entry, path)
        return if entry.dig('from', 'port') == 53 && entry.dig('to', 'port') == 53 &&
                  %w[dns coredns].include?(entry.dig('to', 'service'))

        raise ConfigurationError, "#{path}: UDP redirects require port 53 and the built-in coredns service"
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

        raise ConfigurationError, "#{path} must be an integer port from 1 through 65535"
      end
    end
  end
end
