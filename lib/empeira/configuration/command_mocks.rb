# frozen_string_literal: true

module Empeira
  module Configuration
    class CommandMocks
      FIELDS = %w[path mock_to exit_code].freeze
      NAME = /\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/

      def self.validate!(commands, path = 'mocks.commands', effective: false)
        raise ConfigurationError, "#{path} must be a mapping" unless commands.is_a?(Hash)

        targets = []
        commands.each do |name, entry|
          unless name.is_a?(String) && name.match?(NAME)
            raise ConfigurationError, "#{path} keys must be logical command names"
          end

          location = "#{path}.#{name}"
          entry!(entry, location, effective: effective)
          next unless entry.key?('path')

          target!(entry['path'], location, targets: targets)
          targets << entry['path']
        end
      end

      def self.entry!(entry, path, effective:)
        unless entry.is_a?(Hash) && (entry.keys - FIELDS).empty?
          raise ConfigurationError, "#{path} must contain only path, mock_to and exit_code"
        end

        require_fields!(entry, path) if effective
        mock_to!(entry['mock_to'], "#{path}.mock_to") if entry.key?('mock_to')
        exit_code!(entry['exit_code'], "#{path}.exit_code") if entry.key?('exit_code')
      end

      def self.require_fields!(entry, path)
        FIELDS.each do |field|
          raise ConfigurationError, "#{path}.#{field} is required" unless entry.key?(field)
        end
      end

      def self.exit_code!(value, path)
        return if value == 'passthrough' || (value.is_a?(Integer) && value.between?(0, 255))

        raise ConfigurationError, "#{path} must be an integer from 0 to 255 or passthrough"
      end

      def self.target!(target, path, targets: [])
        unless ServiceConfiguration.safe_target?(target)
          raise ConfigurationError, "#{path}.path must be a safe absolute file path without traversal"
        end

        reserved = ServiceConfiguration::RUNTIME_TARGETS + [Node::ExternalFact::PATH]
        ServiceConfiguration.validate_targets!(target, reserved + targets, path, field: 'path')
      end

      def self.mock_to!(value, path)
        return if value == 'echo' || ServiceConfiguration.safe_target?(value)

        raise ConfigurationError, "#{path} must be echo or a safe absolute executable path"
      end
    end
  end
end
