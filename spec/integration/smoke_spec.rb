# frozen_string_literal: true

require 'ipaddr'
require 'socket'
require 'net/http'
require_relative '../support/eyaml_fixture'
require_relative '../support/hiera_fixture'
require_relative '../support/node_access'
require_relative '../support/login_fixture'

RSpec.describe 'Real runtime smoke', :integration do
  include LiveNodeAccess

  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { File.join(@directory, 'control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } },
                                 progress: Empeira::Progress.new(listener: ->(event) { (@events ||= []) << event }))
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        unless ENV['EMPEIRA_INTEGRATION'] == 'smoke'
          skip 'Set EMPEIRA_INTEGRATION=smoke for the real runtime smoke suite'
        end

        initialize_project(project)
        FileUtils.mkdir_p(File.join(project, 'manifests'))
        eyaml = EyamlFixture.new(project: project, directory: @directory).prepare
        @hiera = HieraFixture.new(project: project, directory: @directory)
        hiera = @hiera.prepare
        File.write(File.join(project, '.empeira.yaml'),
                   YAML.dump('puppetdb' => { 'enabled' => false }, 'eyaml' => eyaml, 'hiera' => hiera,
                             'containers' => { 'additional' => [helper_definition] }))
        @login = LoginFixture.new(directory: @directory)
        File.write(File.join(project, 'manifests/site.pp'),
                   @login.manifest +
                   'notify { "smoke-agent-communication": message => [lookup("smoke_eyaml"), ' \
                   'lookup("hieradata_smoke::value"), lookup("external_value")].join(",") }' \
                   "\nfile { '/tmp/empeira-provider': content => $facts['empeira']['provider'] }")
        runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do
        app.infrastructure.destroy if ENV['EMPEIRA_INTEGRATION'] == 'smoke' && File.directory?(project) && !@destroyed
      end

      it 'runs an isolated control plane and agent, preserves ownership, and cleans up' do
        network = app.infrastructure.up.resource
        RSpec::Mocks.with_temporary_scope do
          allow(app.runner).to receive(:run).and_call_original
          expect(app.runner).not_to receive(:run).with(engine, hash_including(arguments: include('pull')))
          expect(app.runner).not_to receive(:run).with(engine, hash_including(arguments: include('manifest')))
          expect(app.infrastructure.up.changed).to be(false)
        end
        expect(network.isolated).to be(true)
        expect(network.labels).to include('io.empeira.workspace' => app.context.workspace.id)
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        dns = runtime.inspect_service(plan.definitions.fetch('dns'))
        server = runtime.inspect_service(plan.definitions.fetch('server'))
        expect(dns).to include('state' => 'running')
        expect(server).to include('state' => 'running')
        expect(server.dig('networks', plan.network, 'IPAddress')).to match(/\A\d+\.\d+\.\d+\.\d+\z/)
        verify_additional_service(plan, server)
        verify_bootstrap_proxy
        expect(@events.any? do |event|
          event.state == :warning && event.message.include?('hieradata_unavailable')
        end).to be(true)

        app.run_node(hostname: 'smoke-node', provider: 'container')
        node = app.nodes.list.first
        expect(node).to include('hostname' => 'smoke-node', 'state' => 'running')
        expect([0, 2]).to include(node.fetch('last_puppet_exit'))
        definition = Empeira::Node::Definition.new(hostname: 'smoke-node', workspace: app.context.workspace)
        node_resource = runtime.inspect_service(definition)
        expect(runtime.service_exec(node_resource, %w[cat /tmp/empeira-provider]).stdout).to eq('container')
        expect(runtime.service_exec(node_resource, ['cat', Empeira::Node::ExternalFact::PATH]).stdout)
          .to eq(Empeira::Node::ExternalFact.content('container'))
        verify_hiera_and_ssh(server)
        verify_ssh_session(app, name: 'smoke-node', user: @login.username, identity: @login.identity)
        verify_exec_session(app, name: 'smoke-node')
        expect { app.run_node(hostname: 'smoke-node', provider: 'container') }
          .to raise_error(Empeira::Providers::AlreadyExists)
        app.nodes.stop(name: 'smoke-node')
        expect(app.nodes.list.first['state']).to eq('stopped')
        app.nodes.start(name: 'smoke-node')
        expect(app.nodes.list.first['state']).to eq('running')
        app.nodes.destroy(name: 'smoke-node')
        expect(app.nodes.list).to be_empty
        app.infrastructure.destroy
        @destroyed = true
        expect(Empeira::Infrastructure::Store.new(context: app.context).load).to be_nil
      end

      def helper_definition
        { 'name' => 'web-helper', 'image' => { 'repository' => 'docker.io/library/busybox', 'tag' => '1.37.0' },
          'command' => ['httpd', '-f', '-p', '8080'] }
      end

      # rubocop:disable-next Metrics/AbcSize -- Observe real naming, isolation and application reachability together.
      def verify_additional_service(plan, server)
        helper = runtime.inspect_service(plan.definitions.fetch('web-helper'))
        expect(helper.fetch('networks').keys).to eq([plan.network])
        expect(helper.fetch('ports')).to be_empty
        code = 'require "resolv"; require "socket"; ' \
               'address = Resolv.getaddress("web-helper.empeira.internal"); ' \
               'Socket.tcp(address, 8080, connect_timeout: 5) { |s| s.write("GET / HTTP/1.0\r\n\r\n"); puts s.read }'
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
        loop do
          result = runtime.service_exec(server, [Empeira::Node::Certificates::RUBY, '-e', code])
          break if result.success? && result.stdout.include?('404 Not Found')
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise "Additional service DNS/HTTP failed: #{result.exit_status} #{result.stdout} #{result.stderr}"
          end

          sleep 0.25
        end
      end

      # Exercise real SSH and live Hiera changes without a second image or server startup.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- One live node proves SSH, encrypted catalogs and live read-only mounts.
      def verify_hiera_and_ssh(server)
        state = Empeira::Infrastructure::Store.new(context: app.context).load
        record = state.fetch('nodes').fetch('smoke-node')
        args = ['-i', @login.identity.to_s, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=#{@directory}/catalog-known-hosts",
                '-p', record.fetch('ssh_port').to_s]
        if record['ssh_transport'] == 'tunnel'
          args += ['-o', "ProxyCommand=#{Shellwords.join(runtime.ssh_proxy_command('id' => record.fetch('id')))}"]
        end
        result = app.runner.run('ssh', arguments: [*args, "#{@login.username}@127.0.0.1", 'whoami'])
        expect(result).to be_success
        expect(result.stdout.strip).to eq(@login.username)
        @hiera.environment_data.write(YAML.dump('external_value' => 'live-environment'))
        app.infrastructure.up
        catalog = runtime.service_exec(record, %w[/opt/puppetlabs/bin/puppet agent --test --detailed-exitcodes
                                                  --waitforcert 0 --color false], timeout: 60)
        expect([0, 2]).to include(catalog.exit_status)
        expect(catalog.stdout).to include('synthetic-eyaml-value,mounted-module,live-environment')
        mounted = '/etc/puppetlabs/code/environments/production/data/external/external.yaml'
        expect(runtime.service_exec(server, ['touch', mounted])).not_to be_success
      end

      def verify_bootstrap_denial(address)
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        server = runtime.inspect_service(plan.definitions.fetch('server'))
        code = 's=TCPSocket.new(ARGV[0],3128);s.write("GET http://apt.voxpupuli.org/ HTTP/1.0\r\n\r\n");' \
               'abort unless s.read.include?("403 Forbidden")'
        response = runtime.service_exec(server,
                                        [Empeira::Node::Certificates::RUBY, '-rsocket', '-e', code, address])
        expect(response).to be_success
      end

      # rubocop:disable-next Metrics/AbcSize -- Exercise the actual gateway lifecycle in one locked smoke check.
      def verify_bootstrap_proxy
        store = Empeira::Infrastructure::Store.new(context: app.context)
        proxy = Empeira::Network::BootstrapProxy.new(context: app.context, runtime: runtime, store: store)
        requirements = Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04')
        store.with_lock do
          state = store.load
          begin
            proxy.preflight!(state)
            lease = Empeira::Network::Peer::Layout.new(state.fetch('peer_network').fetch('subnet')).lease({})
            address = proxy.start(state, requirements, source: lease.fetch('ip'))
            verify_bootstrap_denial(address)
          ensure
            proxy.cleanup(state)
          end
          expect(state).not_to have_key('bootstrap_proxy')
        end
      end
    end
  end
end
