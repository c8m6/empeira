# frozen_string_literal: true

module Empeira
  module ControlPlane
    # Report only native observations; SIGKILL alone does not establish an OOM kill.
    class StartupFailure < Error
      def initialize(key:, resource:, engine:)
        @resource = resource
        message = "Managed service #{key} is #{resource.fetch('state')} after start; " \
                  "inspect #{engine} logs #{resource.fetch('id')}; " \
                  "#{exit_diagnostic}; #{oom_diagnostic}; #{memory_diagnostic}"
        if key == 'proxy' && resource['oom_killed'] == true
          message += '; increase proxy.memory (MiB) in .empeira.yaml and run empeira up; ' \
                     'check available memory in the container engine host/VM'
        end
        super(Execution::Diagnostics.safe_text(message))
      end

      private

      def exit_diagnostic
        code = @resource['exit_code']
        code.is_a?(Integer) ? "exit code #{code}" : 'exit code unavailable'
      end

      def oom_diagnostic
        case @resource['oom_killed']
        when true then 'confirmed OOM kill (OOMKilled=true)'
        when false then 'OOMKilled=false'
        else 'OOM status unavailable'
        end
      end

      def memory_diagnostic
        bytes = @resource.dig('host_config', 'Memory')
        return 'memory limit unavailable' unless bytes.is_a?(Integer) && bytes >= 0
        return 'memory limit unlimited (runtime reports 0)' if bytes.zero?

        "memory limit #{bytes} bytes (#{format('%g', bytes.fdiv(1024 * 1024))} MiB)"
      end
    end
  end
end
