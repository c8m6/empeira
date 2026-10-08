# frozen_string_literal: true

module Empeira
  module Server
    # OpenVoxDB process layout; custom images may override only these runtime details.
    class PuppetDBRuntime
      PATHS = %w[jar config bootstrap_config data].freeze
      FIELDS = %w[entrypoint user java_arguments main_arguments paths].freeze

      def self.validate!(value, path = 'puppetdb.runtime', effective: false)
        raise ConfigurationError, "#{path} must be a mapping" unless value.is_a?(Hash)

        value.each do |key, item|
          validate_entry!(key, item, path)
        end
        return unless effective

        missing = FIELDS - value.keys
        raise ConfigurationError, "#{path}.#{missing.first} is required" unless missing.empty?
      end

      def self.validate_entry!(key, item, path)
        raise ConfigurationError, "#{path}.#{key} is not supported" unless FIELDS.include?(key)

        if key == 'paths'
          validate_mapping!(item, PATHS, "#{path}.#{key}")
        elsif !valid_item?(key, item)
          raise ConfigurationError, "#{path}.#{key} is invalid"
        end
      end

      def self.validate_mapping!(value, allowed, path)
        raise ConfigurationError, "#{path} must be a mapping" unless value.is_a?(Hash)

        value.each do |key, item|
          raise ConfigurationError, "#{path}.#{key} is not supported" unless allowed.include?(key)

          valid = Runtime.safe_path?(item)
          raise ConfigurationError, "#{path}.#{key} is invalid" unless valid
        end
      end

      def self.valid_item?(key, item)
        case key
        when 'entrypoint' then Runtime.safe_path?(item)
        when 'user' then item.is_a?(String) && item.match?(/\A[0-9]+\z/)
        else Runtime.valid_arguments?(item)
        end
      end

      def self.resolve(config)
        definition = config.fetch('puppetdb').fetch('runtime')
        validate!(definition, effective: true)
        new(definition)
      end

      attr_reader :entrypoint, :user, :paths

      def initialize(definition)
        @entrypoint = definition.fetch('entrypoint')
        @user = definition.fetch('user')
        @paths = definition.fetch('paths')
        @java_arguments = definition.fetch('java_arguments')
        @main_arguments = definition.fetch('main_arguments')
      end

      def command
        [*@java_arguments, '-cp', paths.fetch('jar'), *@main_arguments,
         '--config', paths.fetch('config'), '--bootstrap-config', paths.fetch('bootstrap_config'),
         '--restart-file', "#{paths.fetch('data')}/restartcounter"]
      end
    end
  end
end
