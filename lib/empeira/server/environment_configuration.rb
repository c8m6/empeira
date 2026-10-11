# frozen_string_literal: true

module Empeira
  module Server
    # Apply one native Puppet setting without replacing an image's configuration.
    class EnvironmentConfiguration
      PUPPET = '/opt/puppetlabs/bin/puppet'
      READER = '/empeira-server/environment.rb'

      def initialize(runtime:, plan:)
        @runtime = runtime
        @plan = plan
      end

      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates the native server setting.
      def reconcile(resource)
        return false if current(resource) == '0'

        execute(resource, [PUPPET, 'config', 'set', 'environment_timeout', '0', '--section', 'server',
                           '--confdir', confdir])
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
        execute(resource, [ControlPlane::Health::RUBY, READER, '--confdir', confdir]).stdout.strip
      end

      def execute(resource, arguments)
        result = @runtime.service_exec(resource, arguments)
        return result if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Effective Puppetserver environment timeout',
                                                         tool: arguments.first)
        raise Error, "Cannot reconcile Puppetserver environment_timeout\n#{details}", cause: nil
      end

      def confdir
        File.dirname(@plan.server_runtime.paths.fetch('puppetdb_config'))
      end
    end
  end
end
