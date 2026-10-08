# frozen_string_literal: true

module Empeira
  module Configuration
    class ServiceConfiguration
      RUNTIME_TARGETS = %w[/etc/hosts /etc/hostname /etc/resolv.conf].freeze

      def self.validate!(value, path)
        unless value.is_a?(Hash) && value.size == 2 && %w[content target].all? { |key| value.key?(key) }
          raise ConfigurationError, "#{path} must contain only target and content"
        end

        target = value['target']
        unless safe_target?(target)
          raise ConfigurationError, "#{path}.target must be a safe absolute file path without traversal"
        end

        validate_targets!(target, RUNTIME_TARGETS, path)
        serialize(value['content'], path)
      end

      def self.safe_target?(target)
        target.is_a?(String) && target.start_with?('/') && HieraMountSchema.safe_target?(target.delete_prefix('/'))
      end

      def self.validate_targets!(target, targets, path, field: 'target')
        return unless targets.any? { |other| other == '/' || HieraMountSchema.overlap?(target, other) }

        raise ConfigurationError, "#{path}.#{field} overlaps an existing managed mount target"
      end

      def self.serialize(content, path)
        YAML.safe_dump(content, permitted_classes: [], permitted_symbols: [], aliases: false, line_width: -1)
      rescue Psych::Exception
        raise ConfigurationError, "#{path}.content must contain only YAML data without objects, tags or aliases",
              cause: nil
      end
    end
  end
end
