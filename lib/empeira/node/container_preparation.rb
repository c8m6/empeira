# frozen_string_literal: true

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- Container preparation shares its ownership transaction.
    module ContainerPreparation
      private

      def network_gateway
        Network::Gateway.new(context: context, runtime: @runtime, state: @state)
      end

      def finish_network_bootstrap(record)
        @bootstrap_proxy.cleanup(@state)
        record['network_phase'] = 'runtime'
        save
        network_gateway.phase(record, bootstrap: false)
        refresh_dns
      end

      def ready_server
        raise Error, 'Control plane is down; run empeira up first' unless @state&.dig('resources', 'network', 'id')

        ready_network!
        plan = ControlPlane::Plan.new(context: context)
        expected = @state.dig('control_plane', 'services', 'server', 'id')
        server = @runtime.inspect_service(plan.definitions.fetch('server'), expected_id: expected)
        unless current_server?(server, plan) &&
               ControlPlane::Health.new(runtime: @runtime, plan: plan).ready?('server', 'server' => server)
          raise Error, 'Configuration server is not ready; run empeira up first'
        end

        server
      end

      def ready_network!
        definition = Infrastructure::Definition.new(context: context).network
        expected = @state&.dig('resources', 'network', 'id')
        raise Error, 'Control plane is down; run empeira up first' unless expected

        @runtime.verify_isolated_network(definition, expected_id: expected)
      end

      def current_server?(server, plan)
        server&.dig('labels', 'io.empeira.definition') == plan.definitions.fetch('server').fingerprint
      end

      def reserve(request)
        reject_name!(request.hostname.downcase)
        plan = ControlPlane::Plan.new(context: context)

        image = Image.new(config: context.configuration, request: request, architecture: @runtime.architecture)
        definition = node_definition(request, image, plan)
        record = node_record(request, definition, image)
        @nodes[record.fetch('hostname')] = record
        save
        [record, definition, image]
      end

      def node_record(request, definition, image)
        request.to_h.transform_keys(&:to_s).merge(
          'hostname' => request.hostname.downcase, 'runtime' => context.container_engine,
          'architecture' => @runtime.architecture, **ssh_record,
          'image' => image.reference, 'id' => nil, 'network_phase' => 'bootstrap', 'provisioned' => false,
          'created_at' => Time.now.utc.iso8601,
          'definition' => definition.options
        )
      end

      def ssh_record
        publication = @runtime.node_ssh_publication?
        { 'ssh_host' => '127.0.0.1', 'ssh_port' => publication ? nil : 22,
          'ssh_transport' => publication ? 'loopback' : 'tunnel' }
      end

      def reject_name!(hostname)
        reserved = Network::Naming.new.reserved(context.configuration)
        aliases = [hostname, hostname.delete_suffix('.empeira.internal')]
        taken = @nodes.keys.any? { |key| aliases.include?(key.delete_suffix('.empeira.internal')) }
        return unless aliases.intersect?(reserved) || taken

        raise Providers::AlreadyExists, 'Hostname is reserved or already exists in this workspace'
      end

      def node_definition(request, image, plan)
        init = node_init
        Definition.new(hostname: request.hostname.downcase, workspace: context.workspace,
                       network: plan.network, dns: dns_address(plan), image: image.reference,
                       memory: request.memory, cpus: request.cpus, init: init,
                       **peer_options,
                       command: init == 'systemd' ? ['/sbin/init'] : %w[/usr/sbin/sshd -D -e],
                       **ssh_options(request),
                       environment: plan.node_proxy_environment)
      end

      def peer_options
        layout = Network::Peer::Layout.new(@state.fetch('peer_network').fetch('subnet'))
        { ip: layout.container_lease(@nodes), mac_address: "02:#{SecureRandom.hex(5).scan(/../).join(':')}",
          sysctls: { 'net.ipv6.conf.all.disable_ipv6' => '1', 'net.ipv6.conf.default.disable_ipv6' => '1' } }
      end

      def node_init
        init = context.configuration.dig('node_defaults', 'init')
        @runtime.require_systemd! if init == 'systemd'
        init
      end

      def ssh_options(request)
        ssh_credentials(request.hostname.downcase).prepare_hosts
        { entrypoint: '/usr/local/libexec/empeira-node-start',
          ports: @runtime.node_ssh_publication? ? ['127.0.0.1::22/tcp'] : [],
          mounts: [] }
      end

      def dns_address(plan)
        dns = @runtime.inspect_service(plan.definitions.fetch('dns'),
                                       expected_id: @state.dig('control_plane', 'services', 'dns', 'id'))
        address = dns&.dig('networks', plan.network, 'IPAddress')
        raise Error, 'Empeira DNS is unavailable; run empeira up first' if address.to_s.empty?

        address
      end

      def ssh_credentials(hostname)
        SSHCredentials.new(context: context, runner: @runner, provider: 'container', hostname: hostname)
      end

      def configure(resource, record)
        { 'certname' => record.fetch('hostname'), 'server' => 'server.empeira.internal',
          'environment' => context.configuration.dig('server', 'environment') }.each do |key, value|
          result = @runtime.service_exec(resource,
                                         [Certificates::PUPPET, 'config', 'set', key, value, '--section', 'main'])
          raise Error, 'Node agent configuration failed; node retained for diagnosis' unless result.success?
        end
        refresh_dns
      end

      def refresh_dns
        plan = ControlPlane::Plan.new(context: context)
        ControlPlane::Discovery.new(plan: plan, runtime: @runtime, state: @state).refresh
      end
    end
  end
end
