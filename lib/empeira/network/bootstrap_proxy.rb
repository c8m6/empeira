# frozen_string_literal: true

require 'securerandom'
require 'digest'

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
        @files = ControlPlane::Files.new(context: context, directory: store.directory.join('bootstrap-proxy'))
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

      # rubocop:disable-next Metrics/AbcSize -- Keep native resource creation and readiness separate from brief identity publication.
      def start(state, requirements, source:)
        @generation = state['generation']
        @client_key = client_key(reserved_client(state, source))
        preflight!(state)
        token = SecureRandom.hex(32)
        definition = @plan.bootstrap_proxy(dns: @dns)
        @runtime.ensure_image(definition.options.fetch('image'), recipe: definition.options['recipe'])
        address = @store.operation.resource('bootstrap-proxy') do
          add_client(requirements, source, token)
          start_shared_proxy(definition)
        end
        @url = "http://bootstrap:#{token}@#{address}:3128"
        wait_ready(state, address)
        address
      end

      def cleanup(state, record: nil)
        key = record ? client_key(record) : @client_key
        return unless key

        generation = @generation || state['generation']
        @store.resource_lock('bootstrap-proxy').synchronize do
          path = Pathname(@files.path("clients/#{key}.json"))
          Infrastructure::OwnedFiles.remove(path, root: @store.directory)
          current = @store.read_state
          return unless current && current['generation'] == generation

          @store.with_operation(destructive: true) { reconcile_clients(@store.load) }
        end
        @url = nil
      rescue SystemCallError
        raise Error, 'Cannot remove bootstrap proxy credentials; cleanup is incomplete and Puppet was not run'
      end

      private

      def reserved_client(state, source)
        record = state.fetch('nodes').values.find do |entry|
          (entry.dig('peer', 'ip') || entry.dig('definition', 'ip')) == source
        end
        return record if record

        raise Infrastructure::StateError, 'Bootstrap client has no reserved node instance'
      end

      def add_client(requirements, source, token)
        prepare_clients
        policy = { 'source' => IPAddr.new(source).to_s, 'domains' => requirements.destinations,
                   'authorization' => ["bootstrap:#{token}"].pack('m0') }
        @files.write("clients/#{@client_key}.json", JSON.generate(policy), mode: 0o600)
        write_policy
      end

      def start_shared_proxy(definition)
        current = @store.load
        resource = if current['bootstrap_proxy']
                     @runtime.inspect_service(definition, expected_id: current.fetch('bootstrap_proxy').fetch('id'))
                   else
                     reject_unrecorded!
                     create(current, definition)
                   end
        raise Error, 'Recorded bootstrap proxy is missing; run destroy to recover' unless resource
        unless resource.dig('labels', 'io.empeira.definition') == definition.fingerprint
          raise Error, 'Bootstrap proxy definition changed; destroy its incomplete nodes before retrying'
        end
        return connect_and_verify(resource, definition, current) unless resource['state'] == 'running'

        @runtime.reload_service(resource)
        verify_endpoint(resource)
      end

      # rubocop:disable-next Metrics/AbcSize -- Revoke only one source-bound client and preserve the other bootstrap grants.
      def reconcile_clients(current)
        definition = Services::Definition.new(key: 'bootstrap-proxy', workspace: @context.workspace)
        return remove_empty_proxy(current, definition) if clients.empty?
        return unless current['bootstrap_proxy']

        @plan.subnet = current.fetch('peer_network').fetch('subnet')
        @dns = service_address(current, 'dns')
        write_policy
        resource = @runtime.inspect_service(definition, expected_id: current.fetch('bootstrap_proxy').fetch('id'))
        @runtime.reload_service(resource) if resource && resource['state'] == 'running'
      end

      def remove_empty_proxy(current, definition)
        remove_owned(definition, current.fetch('bootstrap_proxy').fetch('id')) if current['bootstrap_proxy']
        Infrastructure::OwnedFiles.remove(@files.directory, root: @store.directory)
        Infrastructure::OwnedFiles.remove(Pathname(@plan.files.path('bootstrap-squid.conf')), root: @store.directory)
        current.delete('bootstrap_proxy')
        @store.write(current)
      end

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

      def client_key(record)
        instance = Node::Inventory.instance(record)
        Digest::SHA256.hexdigest(instance) if instance
      end

      def prepare_clients
        [@files.directory, Pathname(@files.path('clients'))].each do |path|
          Infrastructure::OwnedFiles.verify_removable!(path, root: @store.directory)
          FileUtils.mkdir_p(path, mode: path == @files.directory ? 0o755 : 0o700)
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Validate private client filenames and ownership before parsing their policies.
      def clients
        directory = Pathname(@files.path('clients'))
        Infrastructure::OwnedFiles.verify_removable!(directory, root: @store.directory)
        return {} unless directory.directory?

        directory.children.sort.to_h do |path|
          unless path.basename.to_s.match?(/\A[0-9a-f]{64}\.json\z/)
            raise Infrastructure::StateError, 'Invalid bootstrap client identity'
          end

          Infrastructure::OwnedFiles.verify_removable!(path, root: @store.directory)
          [path.basename('.json').to_s, JSON.parse(path.read)]
        end
      end

      def write_policy
        # Preserve all authenticated proxy restrictions; only the final source/auth/domain grants vary.
        base = ProxyPolicy.new({ 'global' => [] }, authorization: 'unused').configuration.lines.reject do |line|
          line.start_with?('acl clients ', 'http_access deny !clients', 'http_access deny all')
        end.join
        grants = clients.flat_map { |key, client| client_rules(key, client) }.join("\n")
        @files.write('squid.conf',
                     "#{base}#{grants}\nhttp_access deny all\n".gsub('@EMPEIRA_DNS@', @dns))
      end

      def client_rules(key, client)
        source = IPAddr.new(client.fetch('source')).to_s
        domains = client.fetch('domains')
        authorization = client.fetch('authorization')
        unless domains.all? do |domain|
          ProxyPolicy.valid_domain?(domain)
        end && authorization.match?(%r{\A[A-Za-z0-9+/=]+\z})
          raise Infrastructure::StateError, 'Invalid bootstrap client policy'
        end

        name = "client_#{key}"
        ["acl #{name}_source src #{source}/32",
         "acl #{name}_identity req_header Proxy-Authorization ^Basic[[:space:]]#{Regexp.escape(authorization)}$",
         *ProxyPolicy.domain_rules(domains, name: "#{name}_domains", condition: "#{name}_source #{name}_identity")]
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
          'line=s.gets.to_s;abort(line) unless line.match?(/HTTP\/1\.[01] 403 /)'
      end

      def wait_ready(state, address)
        server = @runtime.inspect_service(@plan.definitions.fetch('server'),
                                          expected_id: state.dig('control_plane', 'services', 'server', 'id'))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        loop do
          @store.operation&.check!
          result = @runtime.service_exec(server, [Node::Certificates::RUBY, '-rsocket', '-e',
                                                  readiness_probe, address], timeout: 3)
          return if result.success?

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            detail = Execution::Diagnostics.native(result, operation: 'Bootstrap proxy readiness', tool: 'ruby',
                                                           url: 'http://bootstrap.invalid/')
            raise Error, "Bootstrap proxy did not become reachable on the peer network\n#{detail}", cause: nil
          end

          sleep 0.2
        end
      end
    end
  end
end
