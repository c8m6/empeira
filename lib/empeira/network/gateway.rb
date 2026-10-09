# frozen_string_literal: true

module Empeira
  module Network
    # One policy, addressing and TCP translation boundary for every peer backend.
    class Gateway
      OFFSETS = { 'gateway' => 2, 'dns' => 3, 'proxy' => 4, 'bootstrap-proxy' => 5 }.freeze
      EXECUTABLE = '/usr/local/libexec/empeira-gateway'

      def self.address(subnet, key = 'gateway')
        Peer::Layout.new(subnet).address(OFFSETS.fetch(key))
      end

      # rubocop:disable-next Metrics/AbcSize -- Compose the complete provider-independent firewall input.
      def self.plan(state:, resolved:, upstreams:, routes:, additional: nil, redirects: [])
        subnet = state.fetch('peer_network').fetch('subnet')
        resolvers = (upstreams + routes.values.flatten + additional_addresses(additional)).uniq.sort
        unless resolvers.all? { |address| IPAddr.new(address).ipv4? }
          raise Error, 'Gateway is IPv4-only; configure reachable IPv4 DNS upstreams'
        end

        { 'version' => 1, 'subnet' => subnet, 'gateway' => address(subnet),
          'dns' => address(subnet, 'dns'), 'resolvers' => resolvers,
          'proxies' => %w[proxy bootstrap-proxy].map { |key| address(subnet, key) },
          'blocked' => blocked_addresses(state), 'entries' => resolved.entries, 'redirects' => redirects }
      end

      def self.blocked_addresses(state)
        state.fetch('nodes', {}).values.filter_map do |node|
          node.dig('peer', 'ip') || node.dig('definition', 'ip') if node['network_phase'] == 'bootstrap'
        end.sort
      end

      def self.additional_addresses(value)
        return [] if value.nil? || value.end_with?('.empeira.internal')

        return [value] if value.match?(/\A[\d.]+\z/)

        Socket.getaddrinfo(value, nil, Socket::AF_INET, Socket::SOCK_STREAM).map { |entry| entry[3] }.uniq
      rescue SocketError
        raise Error, "Gateway DNS resolution failed for additional resolver #{value}", cause: nil
      end

      def initialize(context:, runtime:, state:)
        @context = context
        @runtime = runtime
        @state = state
      end

      def route(resource)
        subnet = @state.fetch('peer_network').fetch('subnet')
        @runtime.configure_workspace_route(resource, gateway: self.class.address(subnet),
                                                     image: ControlPlane::Plan.new(context: @context)
                                                                              .gateway_artifact.fetch(:image))
      end

      def update_phase_plan(ip, bootstrap:)
        files = ControlPlane::Files.new(context: @context)
        plan = JSON.parse(File.binread(files.path('gateway.json')))
        plan['blocked'] = (plan.fetch('blocked') - [ip] + (bootstrap ? [ip] : [])).sort
        files.write('gateway.json', JSON.generate(plan))
      end

      # Bootstrap exclusion is changed inside the gateway, before a new node starts.
      def phase(record, bootstrap:)
        identity = Services::Definition.new(key: 'gateway', workspace: @context.workspace)
        resource = @runtime.inspect_service(identity,
                                            expected_id: @state.dig('control_plane', 'services', 'gateway', 'id'))
        raise Error, 'Gateway is unavailable; run empeira up' unless resource && resource['state'] == 'running'

        ip = record.dig('peer', 'ip') || record.dig('definition', 'ip')
        result = @runtime.service_exec(resource, [EXECUTABLE, bootstrap ? 'block' : 'unblock', ip])
        raise Error, 'Gateway bootstrap firewall reconcile failed' unless result.success?

        update_phase_plan(ip, bootstrap: bootstrap)
      end
    end
  end
end
