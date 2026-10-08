# frozen_string_literal: true

require 'thor'
require_relative 'progress'

module Empeira
  module CLI
    class Base < Thor
      check_unknown_options!
      class_option :container_engine, type: :string, enum: Configuration::Schema::CONTAINER_ENGINES,
                                      desc: 'Override runtime.container_engine'

      def self.exit_on_failure?
        true
      end

      # Thor groups presentation helpers outside its command DSL.
      # rubocop:disable-next Metrics/BlockLength
      no_commands do
        def application(node: false, progress: Empeira::Progress.new, recovery: false)
          overrides = runtime_overrides
          overrides = Configuration::Merge.call(overrides, node_overrides) if node
          Application.new(project_path: Dir.pwd, overrides: overrides, progress: progress, recovery: recovery)
        end

        def progressing(message, node: false, recovery: false)
          renderer = ProgressRenderer.new
          progress = Empeira::Progress.new(listener: renderer)
          renderer.during do
            progress.run(message) { yield application(node: node, progress: progress, recovery: recovery) }
          end
        end

        def runtime_overrides
          return {} unless options[:container_engine]

          { 'runtime' => { 'container_engine' => options[:container_engine] } }
        end

        def node_overrides
          values = options.slice('os', 'version', 'memory', 'cpus').to_h
          %w[memory cpus].each { |key| values[key] = parse_integer(key, values[key]) if values.key?(key) }
          { 'node_defaults' => values }
        end

        def parse_integer(key, value)
          Integer(value, 10)
        rescue ArgumentError
          raise ConfigurationError, "node_defaults.#{key} must be a positive integer"
        end
      end
    end
  end
end
