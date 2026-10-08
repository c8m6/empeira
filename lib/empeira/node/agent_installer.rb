# frozen_string_literal: true

module Empeira
  module Node
    # Selects one native installer from the configured method and guest family.
    module AgentInstaller
      module_function

      def build(config:, requirements:, os:, execute:, copy:)
        method = config.dig('agent', 'install', 'method')
        klass = if method == 'package'
                  AgentPackage
                elsif PackageBootstrap::FAMILIES.fetch(os) == 'debian'
                  AgentRepository
                else
                  DnfAgentRepository
                end
        options = {}
        options[:rpm_options] = requirements.rpm_options unless klass == AgentRepository
        options[:os] = os if klass == AgentPackage
        klass.new(**options, source: requirements.repository, package: requirements.agent.fetch('package'),
                             version: requirements.agent.fetch('version'), execute: execute, copy: copy)
      end
    end
  end
end
