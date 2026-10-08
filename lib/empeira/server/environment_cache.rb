# frozen_string_literal: true

require 'uri'

module Empeira
  module Server
    # Called under the existing workspace lock, immediately before using live Puppet code.
    class EnvironmentCache
      def initialize(plan:, runtime:, state:, persist:)
        @plan = plan
        @runtime = runtime
        @state = state
        @persist = persist
      end

      # rubocop:disable-next Naming/PredicateMethod -- Mutates the server cache and its inventory checkpoint.
      def refresh(server)
        @plan.environment.prepare
        snapshot = { 'server_id' => server.fetch('id'), 'environment' => @plan.config.dig('server', 'environment'),
                     'fingerprint' => CodeSnapshot.new(plan: @plan).fingerprint }
        inventory = @state.fetch('control_plane')
        return false if inventory['environment_cache'] == snapshot

        invalidate(server, snapshot.fetch('environment'))
        inventory['environment_cache'] = snapshot
        @persist.call
        true
      end

      private

      def invalidate(server, environment)
        url = 'https://server.empeira.internal:8140/puppet-admin-api/v1/environment-cache?' \
              "#{URI.encode_www_form(environment: environment)}"
        arguments = [*HTTP.tls_arguments, '--request', 'DELETE', '--output', '/dev/null', '--write-out',
                     '%{http_code}', url] # rubocop:disable Style/FormatStringToken
        result = @runtime.service_exec(server, arguments, timeout: 15)
        return if result.success? && result.stdout.strip == '204'

        raise Error, 'Puppet environment cache invalidation failed; refusing a potentially stale catalog. ' \
                     'Check server admin API access for its own certificate and retry.'
      end
    end
  end
end
