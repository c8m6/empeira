# frozen_string_literal: true

module Empeira
  module Server
    # Apply one native Puppet setting without replacing an image's configuration.
    class EnvironmentConfiguration
      PUPPET = '/opt/puppetlabs/bin/puppet'

      def initialize(runtime:, plan:)
        @runtime = runtime
        @plan = plan
      end

      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates the native server setting.
      def reconcile(resource)
        return false if current(resource) == '0'

        execute(resource, %w[set environment_timeout 0])
        @runtime.stop_service(resource)
        @runtime.start_service(resource)
        true
      end

      def verify!(resource)
        return if current(resource) == '0'

        raise Error, 'Puppetserver environment_timeout is not 0 after startup; the custom entrypoint or ' \
                     'server confdir overrides the managed setting; inspect the server runtime contract'
      end

      private

      def current(resource)
        execute(resource, %w[print environment_timeout]).stdout.strip
      end

      def execute(resource, arguments)
        confdir = File.dirname(@plan.server_runtime.paths.fetch('puppetdb_config'))
        result = @runtime.service_exec(resource, [PUPPET, 'config', *arguments, '--section', 'server',
                                                  '--confdir', confdir])
        return result if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Effective Puppetserver environment timeout',
                                                         tool: 'puppet config')
        raise Error, "Cannot reconcile Puppetserver environment_timeout\n#{details}", cause: nil
      end
    end
  end
end
