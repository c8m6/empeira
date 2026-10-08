# frozen_string_literal: true

module Empeira
  module Configuration
    class HieraMountSchema
      FIELDS = %w[source type name target required].freeze
      NAME = /\A[a-z][a-z0-9_]*\z/
      PATH = %r{\A[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*\z}

      def self.validate!(entries, path = 'hiera.mounts')
        raise ConfigurationError, "#{path} must be an array of mounts" unless entries.is_a?(Array)

        targets = entries.each_with_index.map do |entry, index|
          location = "#{path}.#{index}"
          validate_entry!(entry, location)
          entry['type'] == 'module' ? "modules/#{entry['name']}" : entry['target']
        end
        targets.each_with_index do |target, index|
          next unless targets.take(index).any? { |other| overlap?(target, other) }

          raise ConfigurationError, "#{path}.#{index} overlaps another mount target"
        end
      end

      def self.overlap?(left, right)
        left == right || left.start_with?("#{right}/") || right.start_with?("#{left}/")
      end

      def self.safe_source?(value)
        value.is_a?(String) && !value.empty? && !value.match?(/[\x00-\x1f,]/)
      end

      def self.safe_target?(value)
        value.is_a?(String) && value.match?(PATH) && !value.split('/').intersect?(%w[. ..])
      end

      # Validate every definition even when its optional source is unavailable.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Validate the discriminated public mount shape together.
      def self.validate_entry!(entry, path)
        raise ConfigurationError, "#{path} must be a mount mapping" unless entry.is_a?(Hash)
        raise ConfigurationError, "#{path} contains unsupported fields" unless (entry.keys - FIELDS).empty?
        raise ConfigurationError, "#{path}.source must be a safe local path" unless safe_source?(entry['source'])
        unless %w[module environment].include?(entry['type'])
          raise ConfigurationError, "#{path}.type must be module or environment"
        end
        if entry.key?('required') && ![true, false].include?(entry['required'])
          raise ConfigurationError, "#{path}.required must be a boolean"
        end

        if entry['type'] == 'module'
          unless entry['name'].is_a?(String) && entry['name'].match?(NAME) && !entry.key?('target')
            raise ConfigurationError, "#{path}.name must be a Puppet module name; module mounts do not accept target"
          end
        elsif !safe_target?(entry['target']) || entry.key?('name')
          raise ConfigurationError,
                "#{path}.target must be a safe environment-relative path; " \
                'environment mounts do not accept name'
        end
      end
    end
  end
end
