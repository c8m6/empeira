# frozen_string_literal: true

module Empeira
  module Configuration
    module Addons
      NAME = /\A[a-z][a-z0-9_-]*\z/

      def self.validate!(entries, path = 'addons', effective: false)
        raise ConfigurationError, "#{path} must be a mapping" unless entries.is_a?(Hash)

        entries.each do |name, entry|
          unless name.is_a?(String) && name.size <= 63 && name.match?(NAME)
            raise ConfigurationError, "#{path} contains an invalid addon name"
          end

          entry!(entry, "#{path}.#{name}", effective: effective)
        end
      end

      def self.entry!(entry, path, effective:)
        unless entry.is_a?(Hash) && (entry.keys - %w[git ref config]).empty?
          raise ConfigurationError, "#{path} may contain only git, ref and config"
        end

        require_fields!(entry, path) if effective
        validate_fields!(entry, path)
      end

      def self.validate_fields!(entry, path)
        validate_config!(entry['config'], "#{path}.config") if entry.key?('config')
        if entry.key?('git') && !valid_source?(entry['git'])
          raise ConfigurationError, "#{path}.git must be a credential-free HTTP(S) or SSH Git source"
        end
        return unless entry.key?('ref') && !valid_ref?(entry['ref'])

        raise ConfigurationError, "#{path}.ref must be a nonempty Git reference without control characters"
      end

      def self.validate_config!(config, path)
        raise ConfigurationError, "#{path} must be a mapping" unless config.is_a?(Hash)

        config_value!(config, path)
      end

      def self.config_value!(value, path)
        case value
        when Hash then config_mapping!(value, path)
        when Array then value.each_with_index { |child, index| config_value!(child, "#{path}[#{index}]") }
        when Float
          raise ConfigurationError, "#{path} must contain finite numbers" unless value.finite?
        when String, Integer, TrueClass, FalseClass, NilClass then nil
        else raise ConfigurationError, "#{path} must contain only mappings, arrays and scalar values"
        end
      end

      def self.config_mapping!(value, path)
        value.each do |key, child|
          unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]*\z/)
            raise ConfigurationError, "#{path} has an invalid key; use lowercase letters, digits and underscores"
          end

          config_value!(child, "#{path}.#{key}")
        end
      end

      def self.require_fields!(entry, path)
        %w[git ref].each do |key|
          raise ConfigurationError, "#{path}.#{key} is required" unless entry.key?(key)
        end
      end

      def self.valid_ref?(value)
        value.is_a?(String) && !value.strip.empty? && !value.start_with?('-') && !value.match?(/[\p{Cc}\p{Cf}]/)
      end

      def self.valid_source?(value)
        return false unless Modules::HostGit.valid_remote?(value)
        return true unless value.include?('://')

        uri = URI.parse(value)
        uri.query.nil? && uri.fragment.nil?
      end
    end
  end
end
