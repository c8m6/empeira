# frozen_string_literal: true

module Empeira
  module ControlPlane
    # The plan holds desired, non-secret service definitions. IPs are runtime bindings.
    # Declarative service specifications share one compatibility and naming boundary.
    # rubocop:disable-next Metrics/ClassLength
    class Plan
      attr_accessor :browser_enabled, :subnet
      attr_reader :context, :files, :naming, :server_runtime, :puppetdb_runtime, :additional_configurations

      def initialize(context:)
        @context = context
        @files = Files.new(context: context)
        @additional_configurations = AdditionalConfigurations.new(context: context)
        @naming = Network::Naming.new
        @server_runtime = Server::Runtime.resolve(config)
        @puppetdb_runtime = Server::PuppetDBRuntime.resolve(config)
      end

      def config
        context.configuration
      end

      def network
        Network::Definition.new(workspace: context.workspace, policy: Network::Policy.new).backend_name
      end

      def proxy?
        egress = config.dig('network', 'egress')
        config.dig('proxy', 'enabled') || (egress.is_a?(Hash) && egress['mode'] == 'proxy')
      end

      def database?
        config.dig('puppetdb', 'enabled')
      end

      def volume(key)
        Services::Definition.new(key: "openvox-#{key}", workspace: context.workspace,
                                 storage_revision: 1)
      end

      def volumes
        keys = %w[ca ssl server-data]
        keys.push('postgres-data', 'puppetdb-data') if database?
        keys.to_h { |key| [key, volume(key)] }
      end

      # rubocop:disable-next Metrics/AbcSize -- Compose optional managed services into one provider-neutral plan.
      def definitions(dns: nil)
        common = { network: network, dns: dns, cpus: 1,
                   sysctls: { 'net.ipv6.conf.all.disable_ipv6' => '1', 'net.ipv6.conf.default.disable_ipv6' => '1' } }
        result = {
          'dns' => dns_service,
          'gateway' => service('gateway', **common, **gateway),
          'server' => service('server', **common, **server)
        }
        result['proxy'] = service('proxy', **common, **proxy) if proxy?
        result.merge(database_services(common)).merge(additional_services(common))
              .merge(browser_enabled ? Browser.new(self).definitions(dns: dns) : {})
      end

      def additional_services(common = {})
        config.dig('containers', 'additional').each_with_index.to_h do |entry, index|
          options = { image: image_reference(entry.fetch('image')), memory: 256,
                      environment: proxy_environment_for('').merge(entry.fetch('environment', {})),
                      command: entry.fetch('command', []) }
          location = "containers.additional[#{index}].configuration"
          generated = additional_configurations.options(entry, mounts: common.fetch(:mounts, []), location: location)
          [entry.fetch('name'), service(entry.fetch('name'), **common, **options, **generated)]
        end
      end

      def fingerprints
        definitions.transform_values(&:fingerprint)
      end

      def validate_dns_rewrites!
        entries = config.dig('dns', 'rewrites')
        return if entries.empty?

        targets = definitions.keys.map { |key| naming.hostname(key) }
        entries.each_with_index do |entry, index|
          target = Configuration::DNSRewrites.normalize(entry.fetch('to'))
          next if targets.include?(target)

          raise ConfigurationError, "dns.rewrites[#{index}].to target service #{target} is missing or disabled; " \
                                    'configure the service before running empeira up'
        end
      end

      def bind(source, target, readonly: true)
        raise ConfigurationError, 'Mount paths must not contain commas or newlines' if source.to_s.match?(/[,\r\n]/)

        "type=bind,src=#{source},dst=#{target}#{',readonly' if readonly}"
      end

      def repository_mounts
        [*environment.mounts, *hiera_mounts]
      end

      def project_server_mounts
        @project_server_mounts ||= validate_server_mounts!
      end

      # rubocop:disable-next Metrics/AbcSize -- Compare resolved data mounts with the actual managed definition.
      def validate_server_mounts!
        resolved = Configuration::ServerMounts.new(entries: config.dig('server', 'mounts'),
                                                   project: context.project.path)
        targets = managed_server_mounts.map { |mount| mount.split(',').find { |field| field.start_with?('dst=') }[4..] }
        resolved.verify_targets!(targets)
        @project_server_mounts = resolved.entries.map do |entry|
          bind(entry.fetch('source'), entry.fetch('target'), readonly: entry.fetch('readonly'))
        end
      end

      def module_request
        @module_request ||= Modules::Request.new(context: context)
      end

      def environment
        @environment ||= Environment.new(context: context, hiera: hiera)
      end

      def eyaml_mounts
        destination = eyaml_staged? ? '/empeira-eyaml' : Configuration::Eyaml::DESTINATION
        Configuration::Eyaml.new(config: config.fetch('eyaml'), project: context.project.path)
                            .mounts(destination: destination)
      end

      def eyaml_staged?
        config.dig('eyaml', 'enabled') && server_runtime.startup.fetch('eyaml_keys', 'direct') == 'staged'
      end

      def hiera
        @hiera ||= Configuration::HieraMounts.new(config: config.fetch('hiera'), project: context.project.path,
                                                  environment: config.dig('server', 'environment'))
      end

      def hiera_mounts
        hiera.mounts
      end

      def bootstrap_proxy(dns:)
        options = proxy.merge(network: network, dns: dns, cpus: 1,
                              runtime_ip: subnet && Network::Gateway.address(subnet, 'bootstrap-proxy'),
                              configuration: 'authenticated bootstrap policy',
                              ports: [],
                              command: ['-N', '-f', '/empeira-bootstrap/squid.conf'],
                              mounts: [bind(files.path('bootstrap-squid.conf'), '/empeira-bootstrap/squid.conf'),
                                       'type=tmpfs,dst=/var/log/squid', 'type=tmpfs,dst=/var/spool/squid'])
        service('bootstrap-proxy', **options)
      end

      # rubocop:disable-next Metrics/AbcSize -- Bind one managed recipe to its embedded helper source and image identity.
      def gateway_artifact
        registry = config.dig('images', 'registry')
        artifact = Images::Configuration.artifact(config.dig('images', 'direct_egress'), registry: registry)
        script = Pathname(__dir__).join('../../../resources/gateway/configure.rb').realpath
        files = if artifact[:recipe]
                  { 'configure.rb' => script.binread,
                    'bridge.rb' => script.dirname.join('bridge.rb').binread }
                else
                  {}
                end
        recipe = artifact[:recipe]
        recipe += "\n# configure-sha256: #{Infrastructure::Definition.fingerprint(files)}\n" if recipe
        image = recipe ? Images::Configuration.local_image(recipe, purpose: 'gateway') : artifact[:image]
        artifact.merge(image: image,
                       recipe: recipe, files: files)
      end

      def node_proxy_environment
        return {} unless proxy?

        proxy_environment_for("http://#{naming.hostname('proxy')}:3128")
      end

      private

      def image_reference(data)
        Images::Configuration.reference(data, registry: config.dig('images', 'registry'))
      end

      def service(key, **options)
        ipv6 = { 'net.ipv6.conf.all.disable_ipv6' => '1', 'net.ipv6.conf.default.disable_ipv6' => '1' }
        options[:sysctls] = ipv6.merge(options.fetch(:sysctls, {}))
        Services::Definition.new(key: key, workspace: context.workspace, hostname: naming.hostname(key), **options)
      end

      def storage(key, destination)
        "type=volume,src=#{volume(key).name},dst=#{destination}"
      end

      def dns_service
        service('dns', image: image_reference(config.dig('images', 'dns')), memory: 64,
                       network: network, runtime_ip: subnet && Network::Gateway.address(subnet, 'dns'),
                       sysctls: { 'net.ipv4.ip_forward' => '0', 'net.ipv6.conf.all.disable_ipv6' => '1',
                                  'net.ipv6.conf.default.disable_ipv6' => '1' },
                       mounts: [bind(files.directory, '/empeira')],
                       configuration: files.configuration.fetch('Corefile'),
                       command: ['-conf', '/empeira/Corefile'])
      end

      def database_services(common)
        return {} unless database?

        { 'postgres' => service('postgres', **common, **postgres),
          'puppetdb-backend' => service('puppetdb-backend', **common, **puppetdb),
          'puppetdb' => service('puppetdb', **common, **puppetdb_relay(dns: common[:dns])) }
      end

      def server
        { hiera: hiera.entries, **server_image, **server_startup, memory: config.dig('server', 'memory'),
          cpus: config.dig('server', 'cpus'),
          environment: server_environment, mounts: server_mounts }
      end

      def server_mounts
        [*managed_server_mounts, *project_server_mounts]
      end

      def managed_server_mounts
        mounts = [storage('ca', '/etc/puppetlabs/puppetserver/ca'),
                  storage('ssl', '/etc/puppetlabs/puppet/ssl'),
                  storage('server-data', '/opt/puppetlabs/server/data/puppetserver'),
                  *repository_mounts, *eyaml_mounts]
        mounts + managed_server_start_mounts
      end

      def managed_server_start_mounts
        mounts = []
        mounts << "type=tmpfs,dst=#{Configuration::Eyaml::DESTINATION}" if eyaml_staged?
        mounts << bind(files.path('server-puppetdb.conf'), '/empeira-server/puppetdb.conf') if database?
        mounts << bind(server_start_script, '/empeira-server/start.sh') if database? || eyaml_staged?
        mounts
      end

      def server_startup
        return configured_server_startup unless database? || eyaml_staged?

        { entrypoint: 'dumb-init',
          command: ['/bin/sh', '/empeira-server/start.sh', server_runtime.startup.fetch('entrypoint'),
                    server_runtime.paths.fetch('puppetdb_config'), eyaml_staged? ? 'staged' : 'direct',
                    database? ? 'puppetdb' : 'no-puppetdb', *server_runtime.startup.fetch('arguments')],
          configuration: File.read(server_start_script) }
      end

      def configured_server_startup
        { entrypoint: server_runtime.startup.fetch('entrypoint'), command: server_runtime.startup.fetch('arguments') }
      end

      def server_start_script
        Pathname(__dir__).join('../../../resources/relay/server_start.sh').realpath
      end

      def server_image
        { image: image_reference(config.dig('images', 'server')) }
      end

      def server_environment
        server_runtime.environment(
          certname: naming.hostname('server'), dns_alt_names: 'server',
          ca_hostname: naming.hostname('server'), autosign: 'false',
          server_hostname: naming.hostname('server'), environment_timeout: 'unlimited',
          java_args: '-Xms256m -Xmx768m', max_active_instances: '1',
          puppetdb_enabled: database?.to_s, storeconfigs: database?.to_s,
          reports: database? ? 'puppetdb' : 'log',
          # Upstream entrypoints otherwise rewrite puppetdb.conf from their default URL.
          puppetdb_server_urls: ''
        ).merge(proxy_environment)
      end

      def proxy_environment
        proxy_environment_for(proxy? ? "http://#{naming.hostname('proxy')}:3128" : '')
      end

      def proxy_environment_for(url)
        bypass = Array(config.dig('network', 'egress')).filter_map { |entry| entry['host'] if entry.is_a?(Hash) }
        no_proxy = naming.no_proxy(bypass)
        { 'http_proxy' => url, 'https_proxy' => url, 'HTTP_PROXY' => url, 'HTTPS_PROXY' => url,
          'all_proxy' => '', 'ALL_PROXY' => '', 'no_proxy' => no_proxy, 'NO_PROXY' => no_proxy }
      end

      def postgres
        { image: image_reference(config.dig('images', 'postgres')), memory: 256,
          env_file: files.secret_path,
          configuration: files.configuration.fetch('database-setup.sql'),
          environment: { 'POSTGRES_USER' => 'postgres', 'POSTGRES_DB' => 'puppetdb' },
          mounts: [storage('postgres-data', '/var/lib/postgresql/data'),
                   bind(files.path('database-setup.sql'), '/empeira/setup.sql')],
          command: ['postgres', '-c', 'shared_buffers=64MB', '-c', 'max_connections=50'] }
      end

      def puppetdb
        { configuration: files.configuration.slice('jetty.ini', 'database.conf', 'puppetdb.conf'),
          image: image_reference(config.dig('images', 'puppetdb')), memory: config.dig('puppetdb', 'memory'),
          user: puppetdb_runtime.user, entrypoint: puppetdb_runtime.entrypoint,
          command: puppetdb_runtime.command, env_file: files.secret_path,
          mounts: puppetdb_mounts }
      end

      def puppetdb_mounts
        [storage('puppetdb-data', puppetdb_runtime.paths.fetch('data')),
         bind(files.directory, '/empeira'),
         *%w[jetty.ini database.conf puppetdb.conf].map do |name|
           bind(files.path(name), "#{puppetdb_runtime.paths.fetch('config')}/#{name}")
         end]
      end

      def puppetdb_relay(dns:)
        script = Pathname(__dir__).join('../../../resources/relay/puppetdb.rb').realpath
        certificate = Server::RelayCertificate.new(context: context)
        Browser.new(self).relay_image.merge(
          memory: 96, cpus: 1, user: '0', entrypoint: 'ruby', command: ['/empeira-relay/puppetdb.rb'],
          configuration: File.read(script), runtime_environment: { 'EMPEIRA_DNS_IP' => dns },
          sysctls: { 'net.ipv4.ip_forward' => '0' },
          mounts: [bind(script, '/empeira-relay/puppetdb.rb'),
                   bind(certificate.path('cert.pem'), '/empeira-relay/cert.pem'),
                   bind(certificate.path('key.pem'), '/empeira-relay/key.pem')]
        )
      end

      def proxy
        configured = config.dig('images', 'proxy')
        {
          **Images::Configuration.artifact(configured, registry: config.dig('images', 'registry')),
          memory: 128, runtime_ip: subnet && Network::Gateway.address(subnet, 'proxy'),
          sysctls: { 'net.ipv4.ip_forward' => '0', 'net.ipv6.conf.all.disable_ipv6' => '1',
                     'net.ipv6.conf.default.disable_ipv6' => '1' }, entrypoint: '/usr/sbin/squid-gnutls',
          command: ['-N', '-f', '/empeira-proxy/squid.conf'],
          configuration: files.configuration.fetch('squid.conf'), policy: config.fetch('proxy'),
          mounts: [bind(files.directory, '/empeira-proxy'),
                   'type=tmpfs,dst=/var/log/squid', 'type=tmpfs,dst=/var/spool/squid']
        }
      end

      def gateway
        artifact = gateway_artifact
        {
          **artifact,
          runtime_ip: subnet && Network::Gateway.address(subnet),
          build_files: artifact.fetch(:files), memory: 64, read_only: true, cap_drop: ['ALL'], cap_add: ['NET_ADMIN'],
          security_options: ['no-new-privileges'], sysctls: { 'net.ipv4.ip_forward' => '1',
                                                              'net.ipv6.conf.all.disable_ipv6' => '1',
                                                              'net.ipv6.conf.default.disable_ipv6' => '1',
                                                              'net.ipv4.conf.all.rp_filter' => '0',
                                                              'net.ipv4.conf.default.rp_filter' => '0' },
          mounts: [bind(files.directory, '/empeira-gateway'), 'type=tmpfs,dst=/run,tmpfs-size=1048576']
        }.except(:files)
      end
    end
  end
end
