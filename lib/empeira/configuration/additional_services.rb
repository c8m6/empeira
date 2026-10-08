# frozen_string_literal: true

module Empeira
  module Configuration
    class AdditionalServices
      NAME = /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/
      RESERVED = %w[server puppetdb puppetdb-backend postgres dns proxy gateway browser browser-ui vm-gateway
                    bootstrap-proxy module-installer ca ssl server-data postgres-data
                    puppetdb-data node localhost].freeze
      FIELDS = %w[name image environment command configuration].freeze

      def self.validate!(entries, path)
        raise ConfigurationError, "#{path} must be an array" unless entries.is_a?(Array)

        names = []
        entries.each_with_index do |entry, index|
          location = "#{path}[#{index}]"
          validate_entry!(entry, location)
          name = entry.fetch('name')
          raise ConfigurationError, "#{location}.name collides with another service" if names.include?(name)

          names << name
        end
      end

      def self.validate_entry!(entry, path)
        unless entry.is_a?(Hash) && (entry.keys - FIELDS).empty?
          raise ConfigurationError, "#{path} must contain only name, image, environment, command and configuration"
        end

        name!(entry['name'], path)
        image!(entry['image'], "#{path}.image")
        optional_fields!(entry, path)
      end

      def self.optional_fields!(entry, path)
        environment!(entry.fetch('environment', {}), "#{path}.environment")
        command!(entry['command'], "#{path}.command") if entry.key?('command')
        ServiceConfiguration.validate!(entry['configuration'], "#{path}.configuration") if entry.key?('configuration')
      end

      def self.name!(name, path)
        return if name.is_a?(String) && name.length <= 63 && name.match?(NAME) && !RESERVED.include?(name)

        raise ConfigurationError, "#{path}.name must be a unique lowercase DNS label, excluding built-in names"
      end

      def self.image!(image, path)
        unless image.is_a?(Hash) && image.size == 2 && %w[repository tag].all? { |key| image.key?(key) }
          raise ConfigurationError, "#{path} requires only repository and tag"
        end

        ImageSchema.validate!(image, path, effective: true)
      end

      def self.environment!(environment, path)
        return if environment.is_a?(Hash) && environment.all? do |key, value|
          key.is_a?(String) && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) &&
          value.is_a?(String) && !value.include?("\0")
        end

        raise ConfigurationError, "#{path} must map variable names to strings without null bytes"
      end

      def self.command!(command, path)
        return if command.is_a?(Array) && !command.empty? && command.all? do |value|
          value.is_a?(String) && !value.include?("\0")
        end

        raise ConfigurationError, "#{path} must be a nonempty argument array of strings without null bytes"
      end
    end
  end
end
