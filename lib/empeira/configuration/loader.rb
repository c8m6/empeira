# frozen_string_literal: true

require 'yaml'
require 'pathname'

module Empeira
  module Configuration
    class Loader
      DEFAULTS = File.expand_path('../../../config/defaults.yaml', __dir__).freeze
      CLI_PATHS = [%w[runtime container_engine], %w[node_defaults os], %w[node_defaults version],
                   %w[node_defaults memory], %w[node_defaults cpus]].map(&:freeze).freeze

      attr_reader :ssh_preferences

      def initialize(project_path: Dir.pwd, defaults_path: DEFAULTS, schema: Schema.new,
                     locations: Platform::Locations.new)
        @project_path = ProjectRoot.resolve(project_path).path
        @defaults_path = defaults_path
        @schema = schema
        @locations = locations
        @ssh_preferences = {}.freeze
      end

      def load(overrides: {})
        raise ConfigurationError, 'project path must be an existing directory' unless @project_path.directory?

        defaults = read(@defaults_path)
        project_file = @project_path.join('.empeira.yaml')
        project = read(project_file)
        user = User.new(path: @locations.user_configuration, schema: @schema).load
        @ssh_preferences = Immutable.deep_freeze(user.delete('ssh') || {})
        validate_overrides!(overrides)
        effective([project, user, overrides].reduce(defaults) { |lower, higher| Merge.call(lower, higher) })
      end

      # Recovery operations must not depend on a broken project or user file.
      def load_defaults(overrides: {})
        @ssh_preferences = {}.freeze
        validate_overrides!(overrides)
        effective(Merge.call(read(@defaults_path), overrides))
      end

      private

      def effective(data)
        @schema.validate_effective!(data)
        HieraMounts.new(config: data.fetch('hiera'), project: @project_path,
                        environment: data.dig('server', 'environment'))
        Eyaml.new(config: data.fetch('eyaml'), project: @project_path).mounts
        ServerMounts.new(entries: data.dig('server', 'mounts'), project: @project_path)
        data
      end

      def read(path)
        data = @schema.validate_fragment!(Document.new.read(path))
        data.fetch('network', {}).delete('internet')
        data
      end

      def validate_overrides!(overrides)
        @schema.validate_fragment!(overrides)
        overrides.each do |section, values|
          unless values.is_a?(Hash) && values.keys.all? { |key| CLI_PATHS.include?([section, key]) }
            raise ConfigurationError, "#{section} cannot be overridden through the CLI"
          end
        end
      end
    end
  end
end
