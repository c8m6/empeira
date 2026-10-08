# frozen_string_literal: true

module Empeira
  module Node
    RunRequest = Data.define(:hostname, :provider, :os, :version, :memory, :cpus) do
      def self.from_config(hostname:, provider:, config:)
        defaults = config.fetch('node_defaults').slice('os', 'version', 'memory', 'cpus')
        new(hostname: hostname, provider: provider, **defaults.transform_keys(&:to_sym))
      end

      def initialize(**attributes)
        validate_hostname!(attributes.fetch(:hostname))
        unless Node.registry.names.include?(attributes.fetch(:provider))
          raise Error, "provider must be one of: #{Node.registry.names.join(', ')}"
        end

        validate_resources!(attributes)
        validate_os!(attributes)
        super(**attributes.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value })
      end

      private

      def validate_resources!(attributes)
        %i[memory cpus].each do |key|
          value = attributes.fetch(key)
          next if value.nil? || (value.is_a?(Integer) && value.positive?)

          raise Error, "#{key} must be a positive integer or null"
        end
      end

      def validate_os!(attributes)
        %i[os version].each do |key|
          value = attributes.fetch(key)
          next if value.nil? || (value.is_a?(String) && !value.strip.empty? && value == value.strip)

          raise Error, "#{key} must be a non-empty string without surrounding whitespace or null"
        end
      end

      def validate_hostname!(hostname)
        label = /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/
        return if hostname.is_a?(String) && !hostname.empty? && hostname.length <= 253 &&
                  hostname.split('.', -1).all? { |part| part.match?(label) }

        raise Error, 'hostname must consist of DNS labels of 1 to 63 letters, digits or internal hyphens'
      end
    end
  end
end
