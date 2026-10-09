# frozen_string_literal: true

module Empeira
  module Node
    module AgentInstaller
      module_function

      def build(context:, runtime:, requirements:, execute:, copy:, progress: Progress.new)
        AgentInstallation.new(context: context, runtime: runtime, requirements: requirements,
                              execute: execute, copy: copy, progress: progress)
      end
    end

    class AgentInstallation
      def initialize(context:, runtime:, requirements:, execute:, copy:, progress:)
        @acquisition = Agent::Acquisition.new(context: context, runtime: runtime, progress: progress)
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
