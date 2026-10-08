# frozen_string_literal: true

require 'securerandom'

module Empeira
  module Network
    # A temporary authenticated Squid gateway, managed under the workspace transaction.
    # No credentials enter inventory, image definitions, guest seeds or logs.
    # rubocop:disable-next Metrics/ClassLength -- One ownership transaction coordinates temporary gateway recovery.
    class BootstrapProxy
      attr_reader :url

      def initialize(context:, runtime:, store:)
        @context = context
        @runtime = runtime
        @store = store
        @plan = ControlPlane::Plan.new(context: context)
        @files = @plan.files
      end

      def preflight!(state)
        @plan.subnet = state.fetch('peer_network').fetch('subnet')
        @dns = service_address(state, 'dns')
        service_address(state, 'gateway')
        egress = Network::Egress.new(workspace: @context.workspace, policy: Network::Policy.new)
        resource = @runtime.inspect_network(identifier: egress.backend_name)
        egress.verify_ownership!(resource, expected_id: state.dig('control_plane', 'egress'))
        raise Error, 'Control-plane egress is unavailable; run empeira up first' unless resource

        egress.verify_isolation!(resource)
      end

      def start(state, requirements, source:)
        preflight!(state)
        cleanup(state)
        reject_unrecorded!
        token = SecureRandom.hex(32)
        prepare_policy(token, requirements, source)
        definition = @plan.bootstrap_proxy(dns: @dns)
        @runtime.ensure_image(definition.options.fetch('image'), recipe: definition.options['recipe'])
        resource = create(state, definition)
        address = connect_and_verify(resource, definition, state)
        @url = "http://bootstrap:#{token}@#{address}:3128"
        wait_ready(state, address)
        address
      end

      def cleanup(state)
        return unless state.key?('bootstrap_proxy')

        entry = state.fetch('bootstrap_proxy')
        definition = Services::Definition.new(key: 'bootstrap-proxy', workspace: @context.workspace)
        remove_owned(definition, entry.fetch('id'))
        policy = @files.path('bootstrap-squid.conf')
        File.unlink(policy) if File.exist?(policy) || File.symlink?(policy)
        state.delete('bootstrap_proxy')
        @store.write(state)
        @url = nil
      rescue SystemCallError
        raise Error, 'Cannot remove bootstrap proxy credentials; cleanup is incomplete and Puppet was not run'
      end

      private

      def connect_and_verify(resource, definition, state)
        @runtime.start_service(resource)
        observed = @runtime.inspect_service(definition, expected_id: resource.fetch('id'))
        address = verify_endpoint(observed)
        Gateway.new(context: @context, runtime: @runtime, state: state).route(observed)
        address
      end

      def reject_unrecorded!
        definition = Services::Definition.new(key: 'bootstrap-proxy', workspace: @context.workspace)
        return unless @runtime.inspect_service(definition)

        raise Providers::OwnershipError, 'Unrecorded bootstrap proxy exists; refusing adoption'
      end

      def remove_owned(definition, id)
        @runtime.remove_service(definition, expected_id: id)
      rescue Providers::ExecutionError
        resource = @runtime.inspect_service(definition, expected_id: id)
        @runtime.stop_service(resource) if resource && resource['state'] == 'running'
        raise
      end

      def create(state, definition)
        state['bootstrap_proxy'] = { 'id' => nil }
        @store.write(state)
        resource = @runtime.create_service(definition)
        state['bootstrap_proxy']['id'] = resource.fetch('id')
        @store.write(state)
        resource
      end

      def service_address(state, key)
        expected = state.dig('control_plane', 'services', key, 'id')
        raise Error, "#{key} is not recorded; run empeira up first" unless expected

        resource = @runtime.inspect_service(@plan.definitions.fetch(key), expected_id: expected)
        address = resource&.dig('networks', @plan.network, 'IPAddress')
        raise Error, "#{key} is unavailable; run empeira up first" unless resource&.dig('state') == 'running' && address

        IPAddr.new(address).to_s
      end

      def prepare_policy(token, requirements, source)
        authorization = ["bootstrap:#{token}"].pack('m0')
        config = { 'global' => requirements.destinations }
        policy = ProxyPolicy.new(config, authorization: authorization)
        content = policy.configuration.gsub('@EMPEIRA_DNS@', @dns)
        IPAddr.new(source)
        content = "acl provisioning_vm src #{source}/32\nhttp_access deny !provisioning_vm\n#{content}"
        @files.write('bootstrap-squid.conf', content)
      end

      def verify_endpoint(resource)
        expected = [@plan.network]
        unless resource && resource['state'] == 'running' && resource.fetch('networks').keys.sort == expected &&
               unpublished?(resource)
          raise Providers::OwnershipError, 'Bootstrap proxy has unexpected network attachments or published ports'
        end

        IPAddr.new(resource.fetch('networks').fetch(@plan.network).fetch('IPAddress')).to_s
      end

      def unpublished?(resource)
        resource.fetch('ports').empty? && resource.fetch('published_ports').values.all?(&:nil?)
      end

      def readiness_probe
        's=TCPSocket.new(ARGV[0],3128);s.write("GET http://bootstrap.invalid/ HTTP/1.0\r\n\r\n");' \
          'abort unless s.gets.to_s.match?(/HTTP\/1\.[01] 403 /)'
      end

      def wait_ready(state, address)
        server = @runtime.inspect_service(@plan.definitions.fetch('server'),
                                          expected_id: state.dig('control_plane', 'services', 'server', 'id'))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        loop do
          result = @runtime.service_exec(server, [Node::Certificates::RUBY, '-rsocket', '-e',
                                                  readiness_probe, address], timeout: 3)
          return if result.success?
          raise Error, 'Bootstrap proxy did not become reachable on the peer network' if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
      end
    end
  end
end
