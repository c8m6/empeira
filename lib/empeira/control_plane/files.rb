# frozen_string_literal: true

require 'securerandom'

module Empeira
  module ControlPlane
    # Keep the small generated SQL and TLS configuration templates together.
    # rubocop:disable-next Metrics/ClassLength
    class Files
      attr_reader :directory

      def initialize(context:)
        @context = context
        @directory = context.locations.workspace(context.workspace).join('services')
      end

      def path(name)
        directory.join(name).to_s
      end

      def prepare(upstreams: nil, routes: {}, bootstrap: false)
        FileUtils.mkdir_p(directory, mode: 0o755)
        configuration(bootstrap: bootstrap).each do |name, content|
          next if name == 'squid.conf'

          content = if name == 'Corefile'
                      corefile_content(upstreams:, routes:, bootstrap:)
                    else
                      content.gsub('@HOST_UPSTREAM@', Array(upstreams).join(' '))
                    end
          write(name, content)
        end
        prepare_discovery_files
      end

      def corefile_current?(upstreams:, routes:)
        File.file?(path('Corefile')) && File.binread(path('Corefile')) == corefile_content(upstreams:, routes:)
      end

      def activate_additional_resolver(upstreams:, routes:)
        write('Corefile', corefile_content(upstreams:, routes:))
      end

      def configuration(bootstrap: false)
        {
          'Corefile' => corefile(bootstrap: bootstrap),
          'squid.conf' => Network::ProxyPolicy.new(@context.configuration.fetch('proxy')).configuration,
          'jetty.ini' => jetty, 'database.conf' => database, 'database-setup.sql' => database_setup,
          'puppetdb.conf' => "puppetdb: {}\n",
          'server-puppetdb.conf' => <<~CONFIG
            [main]
            server_urls = https://puppetdb.empeira.internal:8081
            verify_client_certificate = false
          CONFIG
        }
      end

      def prepare_discovery_files
        write('proxy-rules.conf', '') unless File.exist?(path('proxy-rules.conf'))
        write('proxy-clients', "127.0.0.1/32\n") unless File.exist?(path('proxy-clients'))
        write('hosts', '') unless File.exist?(path('hosts'))
      end

      def bind_dns(address)
        IPAddr.new(address)
        write('squid.conf', configuration.fetch('squid.conf').gsub('@EMPEIRA_DNS@', address))
      rescue IPAddr::InvalidAddressError
        raise Error, 'Cannot bind proxy DNS to an invalid CoreDNS address'
      end

      def cleanup
        FileUtils.rm_f(secret_path)
      end

      def credentials(existing:)
        return if File.file?(secret_path)

        if existing
          raise Error,
                'Database credentials are missing for retained storage; restore the workspace credentials'
        end

        content = %w[POSTGRES_PASSWORD EMPEIRA_DB_PASSWORD EMPEIRA_READ_PASSWORD].map do |key|
          "#{key}=#{SecureRandom.hex(32)}\n"
        end.join
        File.write(secret_path, content, mode: 'wx', perm: 0o600)
      end

      def secret_path
        @context.locations.workspace(@context.workspace).join('database.env').to_s
      end

      # rubocop:disable-next Naming/PredicateMethod -- This atomic write returns whether content changed.
      def write(name, content, mode: 0o644)
        return false if File.file?(path(name)) && File.binread(path(name)) == content

        Tempfile.create('configuration-', directory) do |file|
          file.chmod(mode)
          file.write(content)
          file.flush
          File.rename(file.path, path(name))
        end
        true
      end

      def hosts(resources, network)
        naming = Network::Naming.new
        entries = resources.sort.filter_map do |key, resource|
          address = resource.dig('networks', network, 'IPAddress')
          "#{address} #{naming.aliases(key).join(' ')}" if address && !address.empty?
        end
        write('hosts', "#{entries.join("\n")}\n")
      end

      def proxy_clients(resources, network, nodes: {})
        bindings = Network::ProxyBindings.new(context: @context, resources: resources, network: network, nodes: nodes)
        # The workspace parent is private; Squid's mapped service user must read the bind mount.
        rules_changed = write('proxy-rules.conf', bindings.configuration)
        allowed = proxy_allowed(nodes)
        addresses = resources.slice(*allowed).values.filter_map do |resource|
          resource&.dig('networks', network, 'IPAddress')
        end
        clients_changed = write('proxy-clients', "#{(['127.0.0.1/32'] + addresses.reject(&:empty?).sort).join("\n")}\n")
        rules_changed || clients_changed
      end

      def proxy_reload_digest
        content = %w[squid.conf proxy-rules.conf proxy-clients].to_h do |name|
          [name, File.binread(path(name))]
        end
        Infrastructure::Definition.fingerprint(content)
      end

      def proxy_allowed(nodes)
        ['server', *nodes.keys]
      end

      private

      def corefile_content(upstreams:, routes:, bootstrap: false)
        corefile(bootstrap: bootstrap).gsub('@HOST_UPSTREAM@', Array(upstreams).join(' ')) +
          resolver_routes(routes, bootstrap: bootstrap) + rewrite_zones(upstreams: upstreams, routes: routes,
                                                                        bootstrap: bootstrap)
      end

      # Reloadable DNS policy is deliberately outside the container definition fingerprint.
      # Exact rewrites use authoritative discovery; unmatched descendants keep normal forwarding.
      # rubocop:disable-next Metrics/MethodLength
      def rewrite_zones(upstreams:, routes:, bootstrap:)
        Configuration::DNSRewrites.entries(@context.configuration).map do |entry|
          source, target = entry.values_at('from', 'to')
          route = routes.keys.select { |zone| source == zone || source.end_with?(".#{zone}") }.max_by(&:size)
          servers = route ? routes.fetch(route) : upstreams
          <<~CONFIG
            #{source}:53 {
              rewrite stop name exact #{source} #{target}
              template IN AAAA . {
                rcode NOERROR
              }
              hosts /empeira/hosts empeira.internal {
                ttl 1
                reload 1s
              }
              #{forwarders(Array(servers).join(' '), bootstrap: bootstrap, authoritative: true)}
              loop
              reload
            }
          CONFIG
        end.join
      end

      def resolver_routes(routes, bootstrap: false)
        sources = Configuration::DNSRewrites.entries(@context.configuration).map { |entry| entry.fetch('from') }
        routes.except(*sources).map do |zone, addresses|
          forwarding = forwarders(addresses.join(' '), bootstrap: bootstrap)
          "#{zone}:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  #{forwarding}\n  loop\n  reload\n}\n"
        end.join
      end

      def forwarders(servers, bootstrap: false, authoritative: false)
        additional = @context.configuration.dig('dns', 'additional_resolver') unless bootstrap
        exclusion = authoritative ? "    except empeira.internal\n" : ''
        fallback = authoritative ? "forward . #{servers} {\n#{exclusion}  }" : "forward . #{servers}"
        return fallback unless additional

        "forward . #{additional} {\n#{exclusion}    next NXDOMAIN\n    next_on_nodata\n  }\n  #{fallback}"
      end

      # One readable CoreDNS document defines both authoritative and forwarding zones.
      # rubocop:disable-next Metrics/MethodLength
      def corefile(bootstrap: false)
        upstream = @context.configuration.dig('dns', 'upstream')
        servers = upstream['mode'] == 'host' ? '@HOST_UPSTREAM@' : upstream.fetch('servers').join(' ')
        <<~CONFIG
          empeira.internal:53 {
            template IN AAAA {
              rcode NOERROR
            }
            hosts /empeira/hosts {
              ttl 1
              reload 1s
            }
            reload
          }
          .:53 {
            template IN AAAA {
              rcode NOERROR
            }
            hosts /empeira/hosts {
              ttl 1
              reload 1s
              fallthrough
            }
            #{forwarders(servers, bootstrap: bootstrap)}
            loop
            reload
            health :8080
          }
        CONFIG
      end

      def database_setup
        <<~'SQL'
          \getenv writer_password EMPEIRA_DB_PASSWORD
          \getenv reader_password EMPEIRA_READ_PASSWORD
          SELECT format('CREATE ROLE puppetdb LOGIN PASSWORD %L', :'writer_password')
            WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'puppetdb') \gexec
          SELECT format('CREATE ROLE puppetdb_read LOGIN PASSWORD %L', :'reader_password')
            WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'puppetdb_read') \gexec
          ALTER DATABASE puppetdb OWNER TO puppetdb;
          CREATE EXTENSION IF NOT EXISTS pg_trgm;
          GRANT ALL ON SCHEMA public TO puppetdb;
          GRANT USAGE ON SCHEMA public TO puppetdb_read;
          GRANT SELECT ON ALL TABLES IN SCHEMA public TO puppetdb_read;
          ALTER DEFAULT PRIVILEGES FOR ROLE puppetdb IN SCHEMA public GRANT SELECT ON TABLES TO puppetdb_read;
        SQL
      end

      def jetty
        <<~CONFIG
          [jetty]
          host = 0.0.0.0
          port = 8080
        CONFIG
      end

      def database
        <<~CONFIG
          database: {
            subname: "//postgres.empeira.internal:5432/puppetdb"
            username: puppetdb
            password: ${EMPEIRA_DB_PASSWORD}
          }
          read-database: {
            subname: "//postgres.empeira.internal:5432/puppetdb"
            username: puppetdb_read
            password: ${EMPEIRA_READ_PASSWORD}
          }
        CONFIG
      end
    end
  end
end
