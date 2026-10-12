# frozen_string_literal: true

module Empeira
  module Addons
    class Service
      def initialize(context:, runner:)
        @context = context
        @runner = runner
      end

      def names
        @context.configuration.fetch('addons').keys
      end

      def installation(name)
        definition = @context.configuration.fetch('addons')[name]
        raise Error.new(name, 'not configured') unless definition

        Installation.new(name: name, definition: definition, context: @context, runner: @runner)
      end

      def synchronize(missing_only: false)
        errors = names.filter_map do |name|
          installation(name).synchronize(missing_only: missing_only)
          nil
        rescue Error => e
          e.message
        end
        raise Error.new('synchronization', errors.join("\n")) unless errors.empty?
      end

      def execute(name, arguments)
        entry = installation(name)
        _, path, manifest = entry.synchronize(missing_only: true)
        environment = execution_environment(entry, path, [manifest.executable.to_s, *arguments])
        @runner.replace(manifest.executable.to_s, arguments: arguments, environment: environment)
      rescue Execution::LaunchError => e
        raise Error.new(name, e.message, exit_status: e.exit_status), cause: nil
      rescue ExecutionError => e
        raise Error.new(name, e.message), cause: nil
      end

      private

      def execution_environment(entry, path, arguments)
        Environment.new(context: @context, name: entry.name, ref: entry.ref, path: path).export(arguments: arguments)
      end
    end
  end
end
