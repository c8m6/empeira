# frozen_string_literal: true

module Empeira
  module Server
    # One Puppet-compatible runtime contract, with OpenVox defaults in configuration.
    class Runtime
      ENVIRONMENT_KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      SEMANTICS = %w[certname dns_alt_names ca_hostname autosign server_hostname environment_timeout java_args
                     max_active_instances puppetdb_enabled storeconfigs reports puppetdb_server_urls].freeze
      STARTUP_REQUIRED = %w[entrypoint arguments].freeze
      STARTUP = [*STARTUP_REQUIRED, 'eyaml_keys'].freeze
      PATHS = %w[puppetdb_config].freeze
      FIELDS = { 'startup' => STARTUP, 'paths' => PATHS, 'environment_keys' => SEMANTICS }.freeze

      def self.validate!(definition, path = 'server.runtime', effective: false)
        validate_definition!(definition, path, effective: effective)
      end

      def self.validate_definition!(definition, location, effective:)
        validate_fields!(definition, FIELDS.keys, location, effective: effective)
        definition.each do |key, value|
          child = "#{location}.#{key}"
          validate_fields!(value, FIELDS.fetch(key), child, effective: effective)
          validate_component!(key, value, child)
        end
      end

      def self.validate_component!(key, value, location)
        value.each do |field, item|
          raise ConfigurationError, "#{location}.#{field} is invalid" unless valid_item?(key, field, item)
        end
        return unless key == 'environment_keys' && value.values.uniq.size != value.size

        raise ConfigurationError, "#{location} must not reuse an environment variable name"
      end

      def self.valid_item?(component, field, item)
        case component
        when 'startup'
          return valid_arguments?(item) if field == 'arguments'
          return %w[direct staged].include?(item) if field == 'eyaml_keys'

          safe_path?(item)
        when 'paths' then safe_path?(item)
        else item.is_a?(String) && item.match?(ENVIRONMENT_KEY)
        end
      end

      def self.validate_fields!(value, allowed, location, effective:)
        raise ConfigurationError, "#{location} must be a mapping" unless value.is_a?(Hash)

        raise ConfigurationError, "#{location} contains an unsupported field" unless (value.keys - allowed).empty?
        return unless effective

        required = location.end_with?('.startup') ? STARTUP_REQUIRED : allowed
        missing = required - value.keys
        raise ConfigurationError, "#{location}.#{missing.first} is required" unless missing.empty?
      end

      def self.safe_path?(value)
        value.is_a?(String) && value.start_with?('/') && value != '/' &&
          value.match?(%r{\A/[A-Za-z0-9_./-]+\z}) && !value.split('/').intersect?(%w[. ..]) &&
          !value.include?('//')
      end

      def self.valid_arguments?(value)
        value.is_a?(Array) && value.all? do |item|
          item.is_a?(String) && !item.empty? && !item.match?(/[\x00-\x1f\x7f]/)
        end
      end

      def self.resolve(config)
        definition = config.fetch('server').fetch('runtime')
        validate!(definition, effective: true)
        new(definition)
      end
      attr_reader :startup, :paths, :environment_keys

      def initialize(definition)
        @startup = definition.fetch('startup')
        @paths = definition.fetch('paths')
        @environment_keys = definition.fetch('environment_keys')
      end

      def environment(values)
        values.to_h { |semantic, value| [environment_keys.fetch(semantic.to_s), value] }
      end
    end
  end
end
