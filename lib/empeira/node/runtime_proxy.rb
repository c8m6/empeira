# frozen_string_literal: true

module Empeira
  module Node
    # Normal, credential-free guest policy, after verified bootstrap cleanup.
    class RuntimeProxy
      VARIABLES = %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy ALL_PROXY all_proxy].freeze

      def initialize(context:, record:, execute:, persist:)
        @context = context
        @record = record
        @execute = execute
        @persist = persist
      end

      def self.command(context, arguments)
        environment = ControlPlane::Plan.new(context: context).node_proxy_environment
        ['env', *VARIABLES.map { |key| "#{key}=#{environment.fetch(key, '')}" }, *arguments]
      end

      def self.valid_inventory?(entry)
        entry.is_a?(Hash) && (entry.keys - %w[current previous]).empty? && entry.key?('current') &&
          [entry['current'], entry['previous']].compact.all? { |definition| valid_definition?(definition) }
      end

      def self.valid_definition?(definition)
        definition.is_a?(Hash) && definition.keys.sort == %w[direct no_proxy url] &&
          definition['url'] == 'http://proxy.empeira.internal:3128' &&
          definition['no_proxy'].is_a?(String) && definition['no_proxy'].match?(/\A[a-zA-Z0-9.,:-]+\z/) &&
          valid_direct?(definition['direct'])
      end

      def self.valid_direct?(hosts)
        hosts.is_a?(Array) && hosts.all? do |host|
          host.is_a?(String) && host.match?(/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/)
        end
      end

      def reconcile
        desired = definition
        entry = @record['runtime_proxy']
        return false unless desired || entry

        recovered = recover(entry) if entry&.key?('previous')
        previous = [entry&.fetch('current')].compact
        @record['runtime_proxy'] = { 'current' => desired, 'previous' => previous.first }
        @persist.call
        changed = execute(desired, previous)
        @record['runtime_proxy'] = { 'current' => desired }
        @persist.call
        changed || recovered || false
      end

      private

      def recover(entry)
        execute(entry.fetch('current'), [entry['current'], entry['previous']].compact)
      end

      def definition
        environment = ControlPlane::Plan.new(context: @context).node_proxy_environment
        return if environment.empty?

        naming = Network::Naming.new
        internal = naming.reserved(@context.configuration).flat_map { |name| naming.aliases(name) }
        { 'url' => environment.fetch('http_proxy'), 'no_proxy' => environment.fetch('no_proxy'),
          'direct' => ['localhost', '127.0.0.1', *internal,
                       *@context.configuration.dig('network', 'egress').map { |entry| entry.fetch('host') }].uniq }
      end

      def execute(desired, previous)
        helper = Pathname(__dir__).join('../../../resources/nodes/runtime_proxy.rb').read
        request = JSON.generate('desired' => desired, 'accepted' => [desired, *previous].compact)
        result = @execute.call([Certificates::RUBY, '-e', helper, request])
        unless result.success?
          details = Execution::Diagnostics.command(result, operation: 'Normal guest proxy reconciliation', tool: 'ruby')
          raise Error, "Cannot reconcile normal guest proxy; node retained for diagnosis\n#{details}", cause: nil
        end

        JSON.parse(result.stdout).fetch('changed')
      rescue JSON::ParserError, KeyError
        raise Error, 'Cannot verify normal guest proxy reconciliation; node retained for diagnosis', cause: nil
      end
    end
  end
end
