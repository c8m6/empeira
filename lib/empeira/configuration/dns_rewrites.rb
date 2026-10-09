# frozen_string_literal: true

module Empeira
  module Configuration
    class DNSRewrites
      def self.normalize(name)
        name.downcase.delete_suffix('.')
      end

      def self.entries(config)
        normalized = config.dig('dns', 'rewrites').map do |entry|
          entry.transform_values { |name| normalize(name) }
        end
        normalized.sort_by { |entry| entry.fetch('from') }
      end

      def self.validate!(entries, path)
        raise ConfigurationError, "#{path} must be an array" unless entries.is_a?(Array)

        sources = []
        entries.each_with_index do |entry, index|
          location = "#{path}[#{index}]"
          validate_entry!(entry, location)
          source = normalize(entry.fetch('from'))
          raise ConfigurationError, "#{location}.from duplicates another rewrite source" if sources.include?(source)

          sources << source
        end
      end

      def self.validate_entry!(entry, path)
        unless entry.is_a?(Hash) && entry.size == 2 && %w[from to].all? { |key| entry.key?(key) }
          raise ConfigurationError, "#{path} requires only from and to"
        end

        %w[from to].each { |key| hostname!(entry.fetch(key), "#{path}.#{key}") }
        validate_zones!(normalize(entry.fetch('from')), normalize(entry.fetch('to')), path)
      end

      def self.validate_zones!(source, target, path)
        if source == Network::Naming::DOMAIN || source.end_with?(".#{Network::Naming::DOMAIN}")
          raise ConfigurationError, "#{path}.from must be outside empeira.internal; " \
                                    'self references and cycles are forbidden'
        end
        return if target.match?(/\A#{Schema::DNS_LABEL}\.empeira\.internal\z/)

        raise ConfigurationError, "#{path}.to must be an internal service hostname: <service>.empeira.internal"
      end

      def self.hostname!(name, path)
        return if name.is_a?(String) && normalize(name).size <= 253 && name.match?(Schema::DNS_NAME) &&
                  !name.match?(/\A[\d.]+\z/)

        raise ConfigurationError, "#{path} must be an exact DNS hostname without wildcards, URLs or IP addresses"
      end
    end
  end
end
