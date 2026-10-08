# frozen_string_literal: true

require 'find'

module Empeira
  module Configuration
    # Resolve explicit host data without exposing runtime-specific mount options.
    class ServerMounts
      FIELDS = %w[source target readonly].freeze
      RESERVED = %w[/dev /proc /sys].freeze

      def self.validate!(entries, path = 'server.mounts')
        raise ConfigurationError, "#{path} must be an array of mounts" unless entries.is_a?(Array)

        targets = entries.each_with_index.map do |entry, index|
          validate_entry!(entry, "#{path}[#{index}]")
          Pathname(entry.fetch('target')).cleanpath.to_s
        end
        targets.each_with_index do |target, index|
          next unless targets.take(index).any? { |other| overlap?(target, other) }

          raise ConfigurationError, "#{path}[#{index}].target overlaps another server mount target"
        end
      end

      def self.safe_path?(value)
        value.is_a?(String) && !value.strip.empty? && !value.match?(/[\p{Cc},]/)
      end

      def self.overlap?(left, right)
        left == '/' || right == '/' || HieraMountSchema.overlap?(left, right)
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Validate the small public mapping together.
      def self.validate_entry!(entry, path)
        raise ConfigurationError, "#{path} must be a mount mapping" unless entry.is_a?(Hash)
        unless (entry.keys - FIELDS).empty?
          raise ConfigurationError,
                "#{path} only supports source, target and readonly"
        end
        raise ConfigurationError, "#{path}.source must be a safe local path" unless safe_path?(entry['source'])

        target = entry['target']
        unless safe_path?(target) && Pathname(target).absolute? && !target.split('/').include?('..')
          raise ConfigurationError, "#{path}.target must be an absolute path without .., commas or control characters"
        end
        if RESERVED.any? { |reserved| overlap?(Pathname(target).cleanpath.to_s, reserved) }
          raise ConfigurationError, "#{path}.target must not cover /, /dev, /proc or /sys"
        end
        return unless entry.key?('readonly') && ![true, false].include?(entry['readonly'])

        raise ConfigurationError, "#{path}.readonly must be a boolean"
      end

      attr_reader :entries

      def initialize(entries:, project:)
        self.class.validate!(entries)
        @entries = entries.each_with_index.map do |entry, index|
          { 'source' => resolve(entry.fetch('source'), project, index),
            'target' => Pathname(entry.fetch('target')).cleanpath.to_s,
            'readonly' => entry.fetch('readonly', true) }
        end
      end

      def verify_targets!(managed_targets)
        entries.each_with_index do |entry, index|
          next unless managed_targets.any? { |target| self.class.overlap?(entry.fetch('target'), target) }

          raise ConfigurationError, "server.mounts[#{index}].target overlaps an Empeira-managed server mount"
        end
      end

      private

      def resolve(value, project, index)
        source = Pathname(value).expand_path(project).realpath
        unless data_source?(source)
          raise ConfigurationError, "server.mounts[#{index}].source must resolve to a regular file or data directory"
        end

        verify_data_tree!(source, index) if source.directory?
        source.to_s
      rescue SystemCallError
        raise ConfigurationError, "server.mounts[#{index}].source must exist and allow canonical resolution",
              cause: nil
      end

      def data_source?(source)
        self.class.safe_path?(source.to_s) && (source.file? || source.directory?) &&
          RESERVED.none? { |reserved| self.class.overlap?(source.to_s, reserved) }
      end

      def verify_data_tree!(source, index)
        # Do not follow directory symlinks or read file contents. Reject socket/device directories too.
        Find.find(source.to_s, ignore_error: false) do |path|
          stat = File.lstat(path)
          next if stat.file? || stat.directory? || stat.symlink?

          raise ConfigurationError,
                "server.mounts[#{index}].source must not expose sockets, devices or other special files"
        end
      end
    end
  end
end
