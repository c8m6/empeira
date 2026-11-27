# frozen_string_literal: true

module Empeira
  module Node
    module AgentInstaller
      module_function

      # rubocop:disable-next Metrics/ParameterLists -- Pass lifecycle ownership explicitly alongside the existing installer transport callbacks.
      def build(context:, runtime:, requirements:, execute:, copy:, progress: Progress.new, store: nil)
        options = store ? { store: store } : {}
        AgentInstallation.new(context: context, runtime: runtime, requirements: requirements,
                              execute: execute, copy: copy, progress: progress, **options)
      end
    end

    class AgentInstallation
      # rubocop:disable-next Metrics/ParameterLists -- Keep the installer transport and optional lifecycle ownership explicit.
      def initialize(context:, runtime:, requirements:, execute:, copy:, progress:, store: nil)
        @acquisition = Agent::Acquisition.new(context: context, runtime: runtime, progress: progress, store: store)
        @requirements = requirements
        @execute = execute
        @copy = copy
      end

      def install(proxy_url:)
        @acquisition.with_package(@requirements) do |artifact|
          AgentPackage.new(target: @requirements.target, package: @requirements.agent.fetch('package'),
                           artifact: artifact, execute: @execute, copy: @copy,
                           rpm_options: @requirements.rpm_options).install(proxy_url: proxy_url)
        end
      end
    end
  end
end
