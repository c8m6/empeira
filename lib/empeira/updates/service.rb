# frozen_string_literal: true

module Empeira
  module Updates
    class Service
      TARGETS = %w[images modules all].freeze

      def initialize(context: nil, runner: nil, runtimes: nil, build_info: BuildInfo.load, progress: Progress.new)
        @context = context
        @runner = runner
        @runtimes = runtimes
        @build_info = build_info
        @progress = progress
      end

      def self_update
        raise UnavailableFeature,
              'Empeira self-update is not implemented yet. Package replacement requires release packaging.'
      end

      def update(target)
        raise Error, "Select an update target: #{TARGETS.join(', ')}" unless TARGETS.include?(target)
        return update_artifacts(target) unless target == 'all'

        raise UnavailableFeature,
              'update all is unavailable: it includes Empeira itself, and self-update is not implemented.'
      end

      private

      def update_artifacts(target)
        @build_info.require_compatible!(@context.configuration.dig('requirements', 'empeira'))
        Infrastructure::Store.new(context: @context).with_lock do
          runtime = @runtimes.build(@context.container_engine, context: @context, runner: @runner)
          runtime.check_available!
          if target == 'modules'
            Modules.new(context: @context, runtime: runtime, runner: @runner, progress: @progress).synchronize
          else
            Images.new(context: @context, runtime: runtime, progress: @progress).refresh
          end
        end
      end
    end
  end
end
