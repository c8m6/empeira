# frozen_string_literal: true

module Empeira
  module Node
    class Service
      # Preserve explicit injection at the existing provider composition boundary.
      # rubocop:disable-next Metrics/ParameterLists
      def initialize(context:, runner:, providers: Node.registry, runtimes: Runtime.registry, engines: ::Empeira::VM.registry,
                     build_info: BuildInfo.load, progress: Progress.new, ssh_preferences: {})
        @context = context
        @runner = runner
        @providers = providers
        @ssh_preferences = Configuration::SSHPreferences.new(ssh_preferences)
        @dependencies = { context: context, runner: runner, runtimes: runtimes, engines: engines,
                          build_info: build_info, progress: progress }
      end

      def run(request)
        provider(request.provider).run(request)
      end

      %i[start stop destroy inspect_resource shell puppet logs].each do |operation|
        define_method(operation) do |name:, **options|
          record = Infrastructure::Store.new(context: @context).load&.dig('nodes', name.downcase)
          selected = record&.fetch('provider') || 'container'
          provider(selected).public_send(operation, name: name, **options)
        end
      end

      def ssh(name:, user: nil, identity: nil)
        record = Infrastructure::Store.new(context: @context).load&.dig('nodes', name.downcase)
        options = @ssh_preferences.resolve(hostname: name, user: user, identity: identity)
        provider(record&.fetch('provider') || 'container').ssh(name: name, **options)
      end

      def list
        provider('container').list + provider('vm').list
      end

      def names
        Infrastructure::Store.new(context: @context).load&.fetch('nodes', {})&.keys || []
      end

      # The infrastructure caller already holds the workspace mutation lock.
      # rubocop:disable-next Naming/PredicateMethod -- Reconciliation mutates guest resources.
      def reconcile(state:)
        return false unless state

        records = state.fetch('nodes', {}).values
        reconciliation_providers(records).map do |name|
          provider(name).reconcile_all(state: state)
        end.any?
      end

      private

      def reconciliation_providers(records)
        records.map { |record| record.fetch('provider') }.uniq
      end

      def provider(name)
        @providers.build(name, **@dependencies)
      end
    end
  end
end
