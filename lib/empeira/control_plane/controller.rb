# frozen_string_literal: true

module Empeira
  module ControlPlane
    # Called under the infrastructure store's mutation lock.
    # Keep one explicit transaction coordinator for the ordered service lifecycle.
    # rubocop:disable-next Metrics/ClassLength
    class Controller
      def initialize(context:, runtime:, store:, runner: Execution::Runner.new, plan: nil, progress: Progress.new)
        @progress = progress
        @runner = runner
        @context = context
        @runtime = runtime
        @store = store
        @plan = plan || Plan.new(context: context)
        @health = Health.new(runtime: runtime, plan: @plan)
        logger = @runner.method(:debug) if @runner.respond_to?(:debug)
        @direct_resolver = Network::DirectEgress::Resolver.new(logger: logger)
        @observed = {}
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Dependency-ordered reconciliation shares one transaction.
      def up
        preflight unless @desired_images
        load_state
        check_network_architecture!
        check_service_names!
        @gateway_reconciling = true
        lockdown_existing_gateway
        prepare_files
        @progress.stage(20, 'Preparing persistent storage...')
        prepare_storage
        prepare_network_services
        @plan.environment.prepare
        @progress.stage(45, 'Starting PostgreSQL...')
        prepare_postgres
        @progress.stage(60, 'Starting configuration server...')
        prepare_server
        prepare_puppetdb
        @plan.additional_services.each_key { |key| reconcile(key) }
        activate_dns
        prepare_browser
        refresh_redirects
        @progress.stage(95, 'Verifying control plane...')
        finish_reconciliation
        @changed
      rescue StandardError
        lockdown_existing_gateway if @gateway_reconciling
        raise
      ensure
        @desired_images = nil
        @gateway_reconciling = false
      end

      # The browser lifecycle may change only the browser pair. Required workspace
      # services and networks are inspected without being started or reconciled.
      def browser
        load_state
        require_initialized_browser_workspace!
        @plan.browser_enabled = true
        check_service_names!
        require_browser_access_network!
        @dns = require_running_service!('dns')
        definitions = Browser.new(@plan).definitions(dns: @dns)
        check_images(definitions: definitions)
        reconcile_browser('browser', definitions.fetch('browser'))
        record_browser_address
        reconcile_browser('browser-ui', definitions.fetch('browser-ui'))
        browser_url
      ensure
        @desired_images = nil
      end

      def prepare_network_services
        @progress.stage(30, 'Starting CoreDNS and gateways...')
        ensure_egress
        reconcile_bridge('apply')
        reconcile_gateway
        protect_existing_nodes
        reconcile('dns')
        @dns = @observed.fetch('dns').dig('networks', @plan.network, 'IPAddress')
        raise Error, 'DNS service has no address in the isolated network' if @dns.nil? || @dns.empty?

        @plan.files.bind_dns(@dns)
        reconcile_proxy
      end

      def reconcile_bridge(action)
        definition = Network::Definition.new(workspace: @context.workspace, policy: Network::Policy.new)
        definition.allocation = @plan.subnet
        if action == 'apply'
          @inventory['bridge_prepared'] = true
          @inventory['bridge_image'] = @plan.gateway_artifact.fetch(:image)
          save
        end
        network_id = @state.dig('resources', 'network', 'id')
        @runtime.reconcile_workspace_bridge(definition: definition, expected_id: network_id,
                                            image: @inventory.fetch('bridge_image'), action: action)
      end

      def remove_workspace_bridge
        reconcile_bridge('remove') if @inventory['bridge_prepared']
        @inventory.delete('bridge_prepared')
        @inventory.delete('bridge_image')
      end

      def protect_existing_nodes
        return if @state.fetch('nodes', {}).empty?

        definition = @plan.definitions.fetch('dns')
        resource = @runtime.inspect_service(definition, expected_id: recorded('dns'))
        return if resource && !image_changed?(resource, definition) &&
                  resource.dig('labels', 'io.empeira.definition') == definition.fingerprint

        raise Error, 'DNS replacement would invalidate existing node resolver bindings; destroy nodes before empeira up'
      end

      def down
        load_state
        @progress.stage(25, 'Removing service containers...')
        (@inventory.fetch('services').keys - %w[dns proxy gateway]).reverse_each { |key| remove(key) }
        %w[proxy dns gateway].each { |key| remove(key) }
        remove_workspace_bridge
        remove_egress
        @inventory['stopped'] = true
        save if @state['control_plane']
        @changed
      end

      def destroy
        down
        @progress.stage(75, 'Removing persistent volumes and credentials...')
        @inventory.fetch('volumes').each_key do |key|
          @runtime.remove_volume(identity(key), expected_id: @inventory.fetch('volumes').fetch(key).fetch('id'))
          @inventory.fetch('volumes').delete(key)
          save
        end
        cleanup_files
      end

      # rubocop:disable-next Metrics/AbcSize -- One bounded observation includes the central network health.
      def status(state: @store.load)
        load_state(state)
        definitions = service_keys.to_h { |key| [key, identity(key)] }
        expected = @inventory.fetch('services').transform_values { |record| record['id'] }
        @observed = @runtime.inspect_services(definitions, expected_ids: expected)
        report = @observed.to_h { |key, resource| [key.capitalize, readiness(key, resource)] }
        report.merge(summary(report)).merge('Workspace network' =>
          report.values.all? { |value| value == 'running' } ? 'healthy' : 'unhealthy')
      end

      def browser_url
        Browser.url(@observed.fetch('browser-ui'))
      end

      def preflight
        load_state
        @plan.validate_server_mounts!
        check_network_architecture!
        check_service_names!
        @plan.validate_dns_rewrites!
        @plan.validate_network_redirects!
        @plan.module_request.warnings.each { |message| @progress.warning(message) }
        @plan.module_request.verify_available!
        lockdown_existing_gateway
        check_images
      end

      private

      def cleanup_files
        @plan.files.cleanup
        Server::RelayCertificate.new(context: @context).cleanup
        @plan.environment.cleanup
        @plan.additional_configurations.cleanup
      end

      def prepare_browser
        return unless @plan.browser_enabled

        reconcile('browser')
        record_browser_address
        reconcile('browser-ui')
      end

      def check_service_names!
        names = @state.fetch('nodes', {}).keys.map { |name| name.delete_suffix('.empeira.internal') }
        return unless names.intersect?(@plan.definitions.keys)

        raise Error, 'Additional service name collides with an existing node; rename the service or destroy that node'
      end

      def prepare_files
        @plan.additional_configurations.prepare
        @plan.module_request
        prepare_dns_resolution
        @reload_dns = dns_reload_needed?
        @bootstrap_dns = bootstrap_dns?(**@dns_resolution)
        @direct_egress = resolve_direct_egress
        @plan.files.prepare(**@dns_resolution, bootstrap: @bootstrap_dns)
        prepare_gateway_plan
      end

      def prepare_dns_resolution
        resolver = Platform::Resolvers.new(platform: @context.platform, runner: @runner)
        upstreams = resolver.resolve(@plan.config.fetch('dns').fetch('upstream'))
        @dns_resolution = { upstreams: upstreams, routes: resolver.routes }
      end

      def prepare_gateway_plan
        @plan.validate_network_redirects!
        @gateway_plan = Network::Gateway.plan(state: @state, resolved: @direct_egress,
                                              additional: @plan.config.dig('dns', 'additional_resolver'),
                                              redirects: resolved_redirects(existing_redirect_targets),
                                              **@dns_resolution)
        @plan.files.write('gateway.json', JSON.generate(@gateway_plan))
      end

      def existing_redirect_targets
        definitions = @plan.definitions.slice(*@plan.config.dig('network', 'redirects').map do |entry|
          entry.fetch('to').fetch('service')
        end)
        ids = definitions.to_h { |key, _| [key, recorded(key)] }
        @runtime.inspect_services(definitions, expected_ids: ids)
      end

      def resolved_redirects(resources)
        Network::Redirects.new(entries: @plan.config.dig('network', 'redirects'), network: @plan.network,
                               subnet: @plan.subnet).resolve(definitions: @plan.definitions, resources: resources)
      end

      def refresh_redirects
        redirects = resolved_redirects(@observed)
        return if redirects == @gateway_plan.fetch('redirects')

        @gateway_plan['redirects'] = redirects
        @plan.files.write('gateway.json', JSON.generate(@gateway_plan))
        apply_gateway_policy
      end

      def resolve_direct_egress
        config = @plan.config.dig('network', 'egress')
        @direct_resolver.resolve(config)
      end

      def bootstrap_dns?(upstreams:, routes:)
        return false unless @plan.config.dig('dns', 'additional_resolver')
        return true unless @plan.files.corefile_current?(upstreams: upstreams, routes: routes)

        definition = @plan.definitions.fetch('dns')
        resource = @runtime.inspect_service(definition, expected_id: recorded('dns'))
        resource.nil? || resource['state'] != 'running' || stale?('dns', resource, definition)
      end

      def dns_reload_needed?
        return false if @plan.files.corefile_current?(**@dns_resolution)

        definition = @plan.definitions.fetch('dns')
        @runtime.inspect_service(definition, expected_id: recorded('dns'))&.fetch('state') == 'running'
      end

      def activate_dns
        return unless @bootstrap_dns || @reload_dns

        @plan.files.activate_additional_resolver(**@dns_resolution) if @bootstrap_dns
        @runtime.reload_service(@observed.fetch('dns'), signal: 'USR1')
        @changed = true
      end

      def service_keys
        @plan.definitions.keys | @inventory.fetch('services').keys
      end

      def summary(report)
        { 'Control plane' => report.values.all? { |value| value == 'running' } ? 'running' : 'degraded',
          'Readiness' => 'not checked; empeira up verifies readiness',
          'Persistent volumes' => @inventory.fetch('volumes').size.to_s }
      end

      def readiness(key, resource)
        return 'missing' unless resource

        verify_networks!(key, resource)
        definition = @plan.definitions[key]
        return 'stale' if definition && resource.dig('labels', 'io.empeira.definition') != definition.fingerprint

        return gateway_readiness(resource) if key == 'gateway' && resource['state'] == 'running'

        resource['state']
      end

      def gateway_readiness(resource)
        reconcile_bridge('check') if @inventory['bridge_prepared']
        result = @runtime.service_exec(resource, [Network::Gateway::EXECUTABLE, 'check',
                                                  '/empeira-gateway/gateway.json'], timeout: 3)
        result.success? ? 'running' : 'unhealthy; firewall/routing reconcile required'
      rescue Providers::ExecutionError
        'unhealthy; workspace bridge attachment reconcile required'
      end

      def check_images(definitions: @plan.definitions)
        @desired_images = {}
        definitions.each_value do |definition|
          @runtime.ensure_image(definition.options.fetch('image'), recipe: definition.options['recipe'],
                                                                   files: definition.options.fetch('build_files', {}))
          @desired_images[definition.options.fetch('image')] = @runtime.image_id(definition.options.fetch('image'))
        end
      end

      def prepare_postgres
        return unless @plan.database?

        reconcile('postgres')
        @health.wait('postgres', @observed)
        result = @runtime.service_exec(@observed.fetch('postgres'),
                                       ['psql', '-U', 'postgres', '-d', 'puppetdb', '-v', 'ON_ERROR_STOP=1',
                                        '-f', '/empeira/setup.sql'])
        raise Error, 'PostgreSQL roles and pg_trgm initialization failed' unless result.success?
      end

      def prepare_server
        reconcile('server')
        refresh_eyaml_keys if @plan.eyaml_staged?
        Runtime::MountProbe.new(runtime: @runtime).verify(@observed.fetch('server'),
                                                          [@plan.repository_mounts, @plan.eyaml_mounts,
                                                           @plan.project_server_mounts].flatten)
        @health.wait('server', @observed)
        Server::RelayCertificate.new(context: @context).prepare(runtime: @runtime, server: @observed.fetch('server')) if
          @plan.database?
      end

      def refresh_eyaml_keys
        result = @runtime.service_exec(@observed.fetch('server'),
                                       ['/bin/sh', '/empeira-server/start.sh', 'refresh-eyaml'])
        raise Error, 'Puppet Server EYAML key staging failed; inspect server logs' unless result.success?
      end

      def prepare_puppetdb
        return unless @plan.database?

        @progress.stage(85, 'Starting PuppetDB...')
        reconcile('puppetdb-backend')
        @health.wait('puppetdb-backend', @observed)
        reconcile('puppetdb')
        @health.wait('puppetdb', @observed)
      end

      def finish_reconciliation
        remove_disabled
        @health.wait('dns', @observed)
        @health.wait('proxy', @observed) if @plan.proxy?
        update_hosts(reload_proxy: true) if @plan.proxy?
        @inventory['stopped'] = false
        save
        refresh_environment_cache
        @plan.additional_configurations.prune
      end

      def refresh_environment_cache
        refreshed = Server::EnvironmentCache.new(plan: @plan, runtime: @runtime, state: @state,
                                                 persist: method(:save)).refresh(@observed.fetch('server'))
        @changed = refreshed || @changed
      end

      def load_state(state = @store.load)
        @state = state || {}
        @inventory = @state['control_plane'] || { 'services' => {}, 'volumes' => {}, 'egress' => nil }
        @plan.subnet = @state.dig('peer_network', 'subnet')
        @plan.browser_enabled = @inventory.fetch('services').key?('browser')
        @changed = false
      end

      def save
        @state['control_plane'] = @inventory
        @store.write(@state)
      end

      def check_network_architecture!
        services = @inventory.fetch('services')
        return if services.empty? || services.key?('gateway')

        raise Error,
              'Workspace network architecture changed; destroy this alpha workspace with its previous version first'
      end

      def prepare_storage
        storage = Storage.new(runtime: @runtime, plan: @plan, inventory: @inventory, persist: method(:save))
        @changed = storage.prepare || @changed
      end

      def reconcile(key)
        definition = @plan.definitions(dns: @dns).fetch(key)
        resource = @runtime.inspect_service(definition, expected_id: recorded(key))
        if resource && stale?(key, resource, definition)
          remove(key)
          resource = nil
        end
        resource ||= create_service(definition)
        start_service(resource)
        observe_service(key, definition, resource.fetch('id'))
        configure_route(key)
        update_hosts
      end

      def reconcile_browser(key, definition)
        resource = @runtime.inspect_service(definition, expected_id: recorded(key))
        if resource && stale?(key, resource, definition)
          remove(key)
          resource = nil
        end
        resource ||= create_service(definition)
        start_service(resource)
        observe_service(key, definition, resource.fetch('id'))
        configure_route(key)
      end

      def record_browser_address
        address = @observed.fetch('browser').dig('networks', @plan.network, 'IPAddress')
        raise Error, 'Browser service has no address in the isolated network' if address.nil? || address.empty?

        IPAddr.new(address)
        @plan.files.write('browser-address', "#{address}\n")
      rescue IPAddr::InvalidAddressError
        raise Error, 'Browser service has an invalid address in the isolated network'
      end

      def require_initialized_browser_workspace!
        return if @state['control_plane']

        raise Error, "Workspace control plane is not initialized. Start the workspace with 'empeira up' first."
      end

      def require_browser_access_network!
        return if observed_egress

        raise Error, "Required browser access network is not running. Start the workspace with 'empeira up' first."
      end

      def require_running_service!(key)
        definition = @plan.definitions.fetch(key)
        resource = @runtime.inspect_service(definition, expected_id: recorded(key))
        require_service_running!(key, resource)
        if resource.dig('labels', 'io.empeira.definition') != definition.fingerprint
          raise Error, "Required service #{key} is stale. Run 'empeira up' first."
        end

        verify_networks!(key, resource)
        @observed[key] = resource
        address = resource.dig('networks', @plan.network, 'IPAddress')
        require_service_address!(key, address)

        address
      end

      def require_service_running!(key, resource)
        return if resource && resource.fetch('state') == 'running'

        raise Error, "Required service #{key} is not running. Start the workspace with 'empeira up' first."
      end

      def require_service_address!(key, address)
        return unless address.nil? || address.empty?

        raise Error, "Required service #{key} has no workspace address. Run 'empeira up' first."
      end

      def observe_service(key, definition, id)
        @observed[key] = @runtime.inspect_service(definition, expected_id: id)
        require_started!(key, @observed.fetch(key))
        attach_browser_ui_if_needed(key, definition, id)
        verify_networks!(key, @observed.fetch(key))
      end

      def attach_browser_ui_if_needed(key, definition, id)
        return unless key == 'browser-ui' && !@observed.fetch(key).fetch('networks').key?(@plan.network)

        @runtime.attach_egress(Network::Definition.new(workspace: @context.workspace, policy: Network::Policy.new),
                               @observed.fetch(key))
        @observed[key] = @runtime.inspect_service(definition, expected_id: id)
      end

      def require_started!(key, resource)
        return if resource.fetch('state') == 'running'

        raise Error, "Managed service #{key} is #{resource.fetch('state')} after start; " \
                     "inspect #{@context.container_engine} logs #{resource.fetch('id')}"
      end

      def update_hosts(reload_proxy: false)
        # A running container can still be initializing Squid. Defer HUP until its listener is ready.
        Discovery.new(plan: @plan, runtime: @runtime, state: @state).refresh(services: @observed,
                                                                             reload_proxy: reload_proxy)
      end

      def start_service(resource)
        return if resource.fetch('state') == 'running'

        @runtime.start_service(resource)
        @changed = true
      end

      def stale?(key, resource, definition)
        resource.dig('labels', 'io.empeira.definition') != definition.fingerprint ||
          image_changed?(resource, definition) || address_changed?(resource, definition) ||
          (!%w[dns gateway].include?(key) && resource['dns'] != [@dns])
      end

      def address_changed?(resource, definition)
        expected = definition.options['runtime_ip']
        expected && resource.dig('networks', @plan.network, 'IPAddress') != expected
      end

      def image_changed?(resource, definition)
        resource['image_id'] != @desired_images&.fetch(definition.options.fetch('image'), nil)
      end

      def create_service(definition)
        @inventory.fetch('services')[definition.key] = { 'id' => nil }
        save
        resource = @runtime.create_service(definition)
        @inventory.fetch('services')[definition.key] = { 'id' => resource.fetch('id') }
        save
        @changed = true
        resource
      end

      def verify_networks!(key, resource)
        allowed = [@plan.network]
        allowed << egress.backend_name if %w[gateway browser-ui].include?(key)
        unless resource.fetch('networks').key?(@plan.network) &&
               resource.fetch('networks').keys.all? { |name| allowed.include?(name) } &&
               valid_ports?(key, resource)
          raise Providers::OwnershipError, "#{key} has unexpected network attachments or published ports"
        end
      end

      def valid_ports?(key, resource)
        return Browser.valid_ports?(resource) if key == 'browser-ui'

        resource.fetch('ports').empty? && resource.fetch('published_ports', {}).values.all?(&:nil?)
      end

      def reconcile_proxy
        return unless @plan.proxy?

        ensure_egress
        reconcile('proxy')
      end

      def configure_route(key)
        return if %w[gateway browser-ui].include?(key)

        Network::Gateway.new(context: @context, runtime: @runtime, state: @state).route(@observed.fetch(key))
      rescue Providers::ExecutionError
        resource = @runtime.inspect_service(identity(key), expected_id: recorded(key))
        require_started!(key, resource) if resource
        raise
      end

      def lockdown_existing_gateway
        resource = @runtime.inspect_service(identity('gateway'), expected_id: recorded('gateway'))
        return unless resource && resource['state'] == 'running'

        gateway_command(resource, 'lockdown')
      rescue Error
        @runtime.stop_service(resource) if resource
        raise
      end

      # rubocop:disable-next Metrics/AbcSize -- Uplink attachment is ordered behind verified lockdown.
      def reconcile_gateway
        resource = @runtime.inspect_service(identity('gateway'), expected_id: recorded('gateway'))
        if resource && resource['state'] != 'running' && resource.fetch('networks').key?(egress.backend_name)
          @runtime.detach_egress(egress, resource)
        end
        reconcile('gateway')
        gateway_command(@observed.fetch('gateway'), 'lockdown')
        require_redirect_capability
        attach_gateway('gateway')
        apply_gateway_policy
      rescue StandardError
        resource = @observed['gateway']
        @runtime.stop_service(resource) if resource
        raise
      end

      def require_redirect_capability
        return if @plan.config.dig('network', 'redirects').empty?

        result = @runtime.service_exec(@observed.fetch('gateway'),
                                       [Network::Gateway::EXECUTABLE, 'redirects-capability'])
        return if result.success? && result.stdout.strip == 'tcp-redirects-v1'

        raise Error, 'Gateway does not support transparent IPv4/TCP redirects; configure a compatible ' \
                     'images.direct_egress image'
      end

      def apply_gateway_policy
        gateway_command(@observed.fetch('gateway'), 'apply', '/empeira-gateway/gateway.json')
        record_gateway_policy
      end

      def record_gateway_policy
        fingerprint = Infrastructure::Definition.fingerprint(@gateway_plan)
        @changed = true if @inventory['gateway_policy'] != fingerprint
        @inventory['gateway_policy'] = fingerprint
        save
      end

      def gateway_command(resource, *arguments)
        result = @runtime.service_exec(resource, [Network::Gateway::EXECUTABLE, *arguments])
        return if result.success?

        raise Error, 'Gateway firewall reconcile failed; workspace egress remains blocked'
      end

      def attach_gateway(key)
        resource = @observed.fetch(key)
        return if resource.fetch('networks').key?(egress.backend_name)

        @runtime.attach_egress(egress, resource)
        @observed[key] = @runtime.inspect_service(identity(key), expected_id: recorded(key))
        @changed = true
      end

      def ensure_egress
        resource = observed_egress
        unless resource
          save
          resource = @runtime.create_network(definition: egress).resource
          @changed = true
        end
        @inventory['egress'] = resource.id
        save
      end

      def observed_egress
        expected = @inventory['egress']
        resource = @runtime.inspect_network(identifier: egress.backend_name)
        egress.verify_ownership!(resource, expected_id: expected)
        if resource.nil? && expected && @runtime.inspect_network(identifier: expected)
          raise Providers::OwnershipError, 'Recorded egress network exists under a different name'
        end
        return unless resource

        egress.verify_definition!(resource)
        egress.verify_isolation!(resource)
        resource
      end

      def remove_disabled
        (@inventory.fetch('services').keys - @plan.definitions.keys).each { |key| remove(key) }
        update_hosts
      end

      def remove_egress
        result = @runtime.remove_network(definition: egress, expected_id: @inventory['egress'])
        @changed ||= result.changed
        @inventory['egress'] = nil
        save if @state['control_plane']
      end

      def remove(key)
        return unless @inventory.fetch('services').key?(key)

        @changed = @runtime.remove_service(identity(key), expected_id: recorded(key)) || @changed
        @inventory.fetch('services').delete(key)
        @inventory.delete('gateway_policy') if key == 'gateway'
        @observed.delete(key)
        save
      end

      def recorded(key)
        @inventory.fetch('services').dig(key, 'id')
      end

      def identity(key)
        Services::Definition.new(key: key, workspace: @context.workspace)
      end

      def egress
        Network::Egress.new(workspace: @context.workspace, policy: Network::Policy.new)
      end
    end
  end
end
