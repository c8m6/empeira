# frozen_string_literal: true

require 'digest'
require 'socket'

module Empeira
  module Node
    # VM records live in the same locked workspace inventory as container records.
    # rubocop:disable-next Metrics/ModuleLength -- Workspace state and record validation share one boundary.
    module VMState
      def list
        load_state
        health = @peer.health(vm_records.values)
        vm_records.map do |_, record|
          record.slice('hostname', 'provider', 'os', 'version', 'last_puppet_exit').merge(
            'runtime' => 'qemu', 'state' => observed_state(record),
            'network' => if health[record.fetch('hostname')]
                           'running'
                         else
                           (record['state'] == 'stopped' ? 'reserved' : 'degraded')
                         end
          )
        end
      end

      def inspect_resource(name:)
        load_state
        record = vm_records[name.downcase]
        return unless record

        state = record['provisioned'] && @qemu.observed_running?(record) ? :running : :stopped
        Providers::Resource.new(name: record.fetch('hostname'), owner: context.workspace.id, state: state)
      end

      private

      def observed_state(record)
        return 'incomplete' unless record['provisioned']

        return 'running' if @qemu.observed_running?(record)

        return 'preparing' if record['state'] == 'preparing'

        record['state'] == 'stopped' ? 'stopped' : 'missing'
      end

      def vm_records
        @nodes.select { |_, record| record['provider'] == 'vm' }
      end

      def mutate(availability: true)
        @build_info.require_compatible!(context.configuration.dig('requirements', 'empeira'))
        @store.with_lock do
          load_state
          check_runtime!(availability: availability)
          yield
        end
      end

      def load_state(state = @store.load)
        @state = state
        @nodes = state&.fetch('nodes', {}) || {}
      end

      def check_runtime!(availability: true)
        raise Error, 'Control plane is down; run empeira up first' unless @state&.dig('resources', 'network', 'id')
        if @state.fetch('runtime') != context.container_engine
          raise Error, 'Node runtime differs from workspace ownership; restore runtime.container_engine'
        end

        @runtime.check_available! if availability
      end

      def save
        @state['nodes'] = @nodes
        @store.write(@state)
      end

      def fetch_vm(name)
        record = vm_records[name.downcase]
        raise Providers::NotFound, 'VM node does not exist in this workspace' unless record

        record
      end

      def ready_server
        plan = ControlPlane::Plan.new(context: context)
        definition = plan.definitions.fetch('server')
        expected = @state.dig('control_plane', 'services', 'server', 'id')
        server = @runtime.inspect_service(definition, expected_id: expected)
        unless server && server['state'] == 'running' &&
               server.dig('labels', 'io.empeira.definition') == definition.fingerprint &&
               ControlPlane::Health.new(runtime: @runtime, plan: plan).ready?('server', 'server' => server)
          raise Error, 'Configuration server is not ready; run empeira up first'
        end

        server
      end

      def reserve_vm(request, identity, accelerator)
        name = request.hostname.downcase
        reject_vm_name!(name)
        record = vm_record(request, identity, accelerator, name)
        @nodes[name] = record
        save
        record
      end

      def reject_vm_name!(name)
        aliases = [name, name.delete_suffix('.empeira.internal')]
        taken = @nodes.keys.any? { |key| aliases.include?(key.delete_suffix('.empeira.internal')) }
        return unless taken || aliases.intersect?(Network::Naming.new.reserved(context.configuration))

        raise Providers::AlreadyExists, 'Hostname is reserved or already exists in this workspace'
      end

      def vm_record(request, identity, accelerator, name)
        request.to_h.transform_keys(&:to_s).merge(
          'hostname' => name, 'engine' => 'qemu', 'accelerator' => accelerator,
          'architecture' => context.platform.architecture.to_s, 'base_image' => identity.to_h,
          'overlay' => "vms/#{name}/disk.qcow2", 'network' => @state.dig('resources', 'network', 'logical_identity'),
          'mac_address' => vm_mac(name),
          'peer' => peer_lease, 'ssh_port' => @peer.management_port,
          'ssh_layout' => ::Empeira::VM::Management::VERSION, 'pid' => nil,
          'network_phase' => 'bootstrap', 'state' => 'preparing', 'provisioned' => false,
          'certificate_key' => nil, 'last_puppet_exit' => nil,
          'created_at' => Time.now.utc.iso8601
        )
      end

      # rubocop:disable-next Metrics/AbcSize -- Lease and shared DNS/gateway bindings are one identity.
      def peer_lease
        plan = ControlPlane::Plan.new(context: context)
        dns = @runtime.inspect_service(plan.definitions.fetch('dns'),
                                       expected_id: @state.dig('control_plane', 'services', 'dns', 'id'))
        address = dns&.dig('networks', plan.network, 'IPAddress')
        raise Error, 'CoreDNS is unavailable on the peer network' unless address

        Network::Peer::Layout.new(@state.fetch('peer_network').fetch('subnet')).lease(@nodes)
                             .merge('backend' => @peer.key, 'dns' => address,
                                    'gateway' => Network::Gateway.address(@state.fetch('peer_network').fetch('subnet')))
      end

      def vm_mac(_hostname)
        hex = SecureRandom.hex(4)
        "52:54:#{hex.scan(/../).join(':')}"
      end

      def base_for(record)
        fields = record.fetch('base_image').transform_keys(&:to_sym)
        identity = Images::Identity.new(**fields)
        context.locations.image(identity).join('base.qcow2')
      end

      def lifecycle_result(name, state, changed:)
        resource = Providers::Resource.new(name: name, owner: context.workspace.id, state: state)
        Providers::Result.new(resource: resource, changed: changed)
      end
    end
  end
end
