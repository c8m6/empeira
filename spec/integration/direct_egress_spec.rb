# frozen_string_literal: true

RSpec.describe 'Direct egress gateway', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { File.join(@directory, 'control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=direct-egress for the real gateway suite' unless
          ENV['EMPEIRA_INTEGRATION'] == 'direct-egress'

        initialize_project(project)
        @probes = []
        write_config([])
        @app = application(engine)
        @runtime = Empeira::Runtime.registry.build(engine, context: @app.context, runner: @app.runner)
        @runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do
        @probes&.reverse_each { |definition, id| @runtime.remove_service(definition, expected_id: id) }
        @runtime.remove_service(@target_definition, expected_id: @target_id) if @target_definition
      ensure
        (@active_app || @app)&.infrastructure&.destroy
      end

      it 'separates node source ranges from infrastructure and revokes the former grants on scope changes' do
        @app.infrastructure.up
        target_ip = start_target
        write_config([], nodes: [{ 'ip' => target_ip, 'ports' => [8443] }])
        @active_app = application(engine)
        @active_app.infrastructure.up
        plan = Empeira::ControlPlane::Plan.new(context: @active_app.context)
        state = Empeira::Infrastructure::Store.new(context: @active_app.context).load
        infrastructure = start_probe(plan, state)
        node_sources = [32, 96].map { |offset| start_probe(plan, state, offset: offset) }
        node_sources.each do |node|
          expect(tcp_probe(@runtime, node, target_ip, 8443, success: true)).to be_success
        end
        expect(tcp_probe(@runtime, infrastructure, target_ip, 8443, success: false)).to be_success
        write_config([{ 'ip' => target_ip, 'ports' => [8444] }])
        @active_app = application(engine)
        @active_app.infrastructure.up
        node_sources.each do |node|
          expect(tcp_probe(@runtime, node, target_ip, 8443, success: false)).to be_success
          expect(tcp_probe(@runtime, node, target_ip, 8444, success: false)).to be_success
        end
        expect(tcp_probe(@runtime, infrastructure, target_ip, 8444, success: true)).to be_success
      end

      it 'permits only the configured TCP port through the common Docker/Podman plan' do
        @app.infrastructure.up
        target_ip = start_target
        write_config([{ 'host' => 'allowed.example.test', 'ports' => [8443] }])
        @active_app = application(engine)
        resolver = Empeira::Network::DirectEgress::Resolver.new(lookup: ->(_host) { [target_ip] })
        allow(Empeira::Network::DirectEgress::Resolver).to receive(:new).and_return(resolver)

        @active_app.infrastructure.up
        direct_runtime = Empeira::Runtime.registry.build(engine, context: @active_app.context,
                                                                 runner: @active_app.runner)
        plan = Empeira::ControlPlane::Plan.new(context: @active_app.context)
        state = Empeira::Infrastructure::Store.new(context: @active_app.context).load
        Empeira::ControlPlane::Discovery.new(plan: plan, runtime: direct_runtime, state: state).refresh
        server = start_probe(plan, state)
        expect(tcp_probe(direct_runtime, server, target_ip, 8443, success: true)).to be_success
        expect(tcp_probe(direct_runtime, server, target_ip, 8444, success: false)).to be_success
        server_id = server.fetch('id')
        gateway_id = state.dig('control_plane', 'services', 'gateway', 'id')
        write_config([{ 'ip' => target_ip, 'ports' => [8444] }])
        @active_app = application(engine)
        @active_app.infrastructure.up
        expect(tcp_probe(direct_runtime, server, target_ip, 8443, success: false)).to be_success
        expect(tcp_probe(direct_runtime, server, target_ip, 8444, success: true)).to be_success
        updated = Empeira::Infrastructure::Store.new(context: @active_app.context).load
        expect(direct_runtime.inspect_service(@probe_definition, expected_id: server_id).fetch('id')).to eq(server_id)
        expect(updated.dig('control_plane', 'services', 'gateway', 'id')).to eq(gateway_id)
        write_config([])
        @active_app = application(engine)
        @active_app.infrastructure.up
        expect(tcp_probe(direct_runtime, server, target_ip, 8444, success: false)).to be_success
      end

      def application(engine)
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end

      def write_config(egress, nodes: [])
        File.write(File.join(project, '.empeira.yaml'),
                   YAML.dump('puppetdb' => { 'enabled' => false },
                             'network' => { 'egress' => { 'infrastructure' => egress, 'nodes' => nodes } }))
      end

      def start_target
        image = 'docker.io/library/busybox:1.37.0'
        @runtime.ensure_image(image)
        egress = Empeira::Network::Egress.new(workspace: @app.context.workspace,
                                              policy: Empeira::Network::Policy.new)
        command = 'mkdir -p /www; echo allowed > /www/index.html; ' \
                  'httpd -h /www -p 8443; exec httpd -f -h /www -p 8444'
        @target_definition = Empeira::Services::Definition.new(
          key: 'direct-target', workspace: @app.context.workspace, image: image,
          network: egress.backend_name, memory: 32, entrypoint: 'sh', command: ['-c', command]
        )
        target = @runtime.create_service(@target_definition)
        @target_id = target.fetch('id')
        @runtime.start_service(target)
        @runtime.inspect_service(@target_definition, expected_id: @target_id)
                .dig('networks', egress.backend_name, 'IPAddress')
      end

      def start_probe(plan, state, offset: nil)
        image = plan.gateway_artifact.fetch(:image)
        subnet = state.fetch('peer_network').fetch('subnet')
        @probe_definition = Empeira::Services::Definition.new(
          key: "gateway-probe-#{offset || 'infra'}", workspace: @app.context.workspace, image: image,
          network: plan.network, runtime_ip: offset && Empeira::Network::Peer::Layout.new(subnet).address(offset),
          memory: 32, entrypoint: 'sleep', command: ['infinity'], cap_drop: ['ALL']
        )
        probe = @runtime.create_service(@probe_definition)
        @probes << [@probe_definition, probe.fetch('id')]
        @runtime.start_service(probe)
        @runtime.configure_workspace_route(probe, gateway: Empeira::Network::Gateway.address(subnet), image: image)
        probe
      end

      def tcp_probe(runtime, server, host, port, success:)
        code = if success
                 'Socket.tcp(ARGV[0],ARGV[1].to_i,connect_timeout:5) {' \
                   '|s| s.write("GET / HTTP/1.0\\r\\n\\r\\n"); abort unless s.read.include?("allowed") }'
               else
                 'begin; Socket.tcp(ARGV[0],ARGV[1].to_i,connect_timeout:2) { abort "unexpected access" }; ' \
                   'rescue SystemCallError,IOError; end'
               end
        runtime.service_exec(server, ['/usr/local/bin/ruby', '-rsocket', '-e', code,
                                      host, port.to_s], timeout: 10)
      end
    end
  end
end
