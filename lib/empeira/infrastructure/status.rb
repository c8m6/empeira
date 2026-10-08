# frozen_string_literal: true

module Empeira
  module Infrastructure
    class Status
      attr_reader :report

      def initialize(context:, build_info:, definition:)
        @context = context
        @definition = definition
        requirement = context.configuration.fetch('requirements').fetch('empeira')
        @report = {
          'Workspace' => context.workspace.id, 'Platform' => "#{context.platform.os}/#{context.platform.architecture}",
          'Empeira version' => build_info.version, 'Project Empeira requirement' => requirement || 'none',
          'Version requirement' => build_info.requirement_status(requirement),
          'Configured runtime' => context.container_engine, 'Owning runtime' => 'unknown',
          'Network' => 'unknown', 'Infrastructure' => 'unknown', 'Infrastructure fingerprint' => 'unknown'
        }
      end

      def record(state)
        @state = state
        report['Owning runtime'] = state&.fetch('runtime') || 'none recorded'
        report['Infrastructure fingerprint'] = fingerprint_status
        report['Runtime ownership'] =
          if state && state.fetch('runtime') != @context.container_engine
            'mismatch; restore owning runtime for cleanup'
          else
            'consistent'
          end
      end

      def observe(resource)
        report['Network'] = network_status(resource)
        report['Infrastructure'] = infrastructure_status(resource)
        return unless resource
        return if resource.labels['io.empeira.definition'] == @definition.network.labels.fetch('io.empeira.definition')

        report['Infrastructure fingerprint'] = 'stale runtime definition'
        report['Infrastructure'] = 'stale'
      end

      private

      def network_status(resource)
        return 'absent' unless resource

        resource.isolated ? 'isolated' : 'unsafe isolation'
      end

      def fingerprint_status
        return 'unrecorded' unless @state

        @state.fetch('fingerprint') == @definition.fingerprint ? 'current' : 'stale'
      end

      def missing_status
        return 'down; persistent data retained' if @state&.dig('control_plane', 'stopped')

        @state ? 'missing; reconciliation required' : 'down'
      end

      def infrastructure_status(resource)
        return missing_status unless resource

        return 'unsafe; isolation cannot be verified' unless resource.isolated
        return 'recoverable; local state incomplete' unless @state&.dig('resources', 'network', 'id')

        fingerprint_status == 'current' ? 'up' : 'stale'
      end
    end
  end
end
