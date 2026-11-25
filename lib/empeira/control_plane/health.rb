# frozen_string_literal: true

module Empeira
  module ControlPlane
    # rubocop:disable-next Metrics/ClassLength -- Readiness and setup share one native PostgreSQL probe.
    class Health
      RUBY = '/opt/puppetlabs/puppet/bin/ruby'
      POSTGRES_SETUP = <<~SQL
        SELECT (SELECT count(*) FROM pg_roles WHERE rolname IN ('puppetdb', 'puppetdb_read')) = 2
          AND EXISTS (SELECT FROM pg_extension WHERE extname = 'pg_trgm')
          AND EXISTS (SELECT FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba
                      WHERE d.datname = current_database() AND r.rolname = 'puppetdb');
      SQL

      attr_reader :postgres_initialized

      def initialize(runtime:, plan:)
        @runtime = runtime
        @plan = plan
      end

      def wait(key, resources)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @plan.config.dig('server', 'timeout')
        interval = 0.25
        loop do
          return if ready?(key, resources)

          verify_proxy_running!(resources) if key == 'proxy'
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            raise Error,
                  "#{key} did not become ready within server.timeout; inspect empeira status and owned service logs\n" \
                  "#{@failure}"
          end

          sleep [interval, remaining].min
          interval = [interval * 2, 2].min
        end
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Each service has its own concrete readiness probe.
      def ready?(key, resources)
        resource = resources[key]
        return false unless resources.dig(key, 'state') == 'running'

        case key
        when 'server' then check(resource, [*tls_curl, 'https://server.empeira.internal:8140/status/v1/simple'],
                                 'running')
        when 'postgres' then postgres_ready?(resource)
        when 'puppetdb-backend'
          check(resources['server'], [*http_curl, 'http://puppetdb-backend.empeira.internal:8080/pdb/query/v4/nodes'])
        when 'puppetdb' then puppetdb_ready?(resources['server'])
        when 'dns' then dns_ready?(resources)
        when 'proxy' then proxy_ready?(resources)
        else false
        end
      end

      def http_curl
        Server::HTTP.arguments
      end

      def tls_curl
        Server::HTTP.tls_arguments
      end

      private

      def postgres_ready?(resource)
        @postgres_initialized = false
        result = @runtime.service_exec(resource, ['psql', '-X', '-U', 'postgres', '-d', 'puppetdb',
                                                  '-v', 'ON_ERROR_STOP=1', '-Atc', POSTGRES_SETUP])
        @postgres_initialized = result.success? && result.stdout.strip == 't'
        return true if result.success? && %w[t f].include?(result.stdout.strip)

        @failure = Execution::Diagnostics.native(result, operation: 'Probe PostgreSQL setup', tool: 'psql')
        false
      rescue Empeira::ExecutionError
        false
      end

      def verify_proxy_running!(resources)
        resource = @runtime.inspect_service(@plan.definitions.fetch('proxy'),
                                            expected_id: resources.fetch('proxy').fetch('id'))
        raise Error, 'Managed service proxy disappeared during readiness' unless resource
        return if resource.fetch('state') == 'running'

        raise StartupFailure.new(key: 'proxy', resource: resource, engine: @plan.context.container_engine)
      end

      def puppetdb_ready?(server)
        path = '/pdb/query/v4/nodes'
        check(server, [*http_curl, "http://puppetdb.empeira.internal:8080#{path}"]) &&
          check(server, [*http_curl, '--cacert', '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
                         "https://puppetdb.empeira.internal:8081#{path}"])
      end

      def check(resource, arguments, expected = nil)
        return false unless resource
        return check_http?(resource, arguments, expected) if http_probe?(arguments)

        result = @runtime.service_exec(resource, arguments)
        return true if result.success? && (expected.nil? || result.stdout.strip == expected)

        @failure = Execution::Diagnostics.native(result, operation: 'Probe control-plane readiness',
                                                         tool: arguments.first)
        false
      rescue Empeira::ExecutionError
        false
      end

      def http_probe?(arguments)
        arguments.first == 'curl' && !arguments.include?('--write-out')
      end

      def check_http?(resource, arguments, expected)
        result = @runtime.service_exec(resource, [*arguments[0...-1], '--include', arguments.last])
        body = Server::HTTP.response(result)[:body]
        return true if result.success? && (expected.nil? || body.strip == expected)

        @failure = Server::HTTP.failure(result, url: arguments.last, operation: 'Probe control-plane readiness')
        false
      end

      def proxy_ready?(resources)
        arguments = %w[curl --silent --max-time 5 --noproxy localhost --proxy
                       http://proxy.empeira.internal:3128 --output /dev/null --write-out]
        # Squid's denial must be observable, even when no destination is allowed.
        arguments.push('%{http_code}', 'http://empeira-denied.invalid/') # rubocop:disable Style/FormatStringToken
        check(resources['server'], arguments, '403')
      end

      def dns_ready?(resources)
        names = resources.keys.map { |key| @plan.naming.hostname(key) }
        code = 'require "resolv"; ARGV.each { |name| Resolv.getaddress(name) }'
        check(resources['server'], [RUBY, '-e', code, *names])
      end
    end
  end
end
