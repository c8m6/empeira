# frozen_string_literal: true

RSpec.describe 'Real Puppet development cycle', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { Pathname(@directory).join('control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
      let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=development for cache and APT smoke checks' unless
          ENV['EMPEIRA_INTEGRATION'] == 'development'
        initialize_project(project)
        project.join('.empeira.yaml').write(
          YAML.dump('puppetdb' => { 'enabled' => false },
                    'bootstrap' => { 'packages' => { 'install' => { 'default' => ['hello'] } } })
        )
        project.join('manifests').mkpath
        project.join('modules/cache_fixture/lib/puppet/functions/cache_fixture').mkpath
        project.join('manifests/site.pp').write("file { '/tmp/catalog-value': content => cache_fixture::value() }\n")
        write_function('first')
        runtime.check_available!
        @available = true
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after { app.infrastructure.destroy if @available }

      it 'keeps loaded code on a second catalog and invalidates edits without restarting the server' do
        app.infrastructure.up
        server = service('server')
        measure('first') { app.run_node(hostname: 'cache-node', provider: 'container') }
        expect(runtime.service_exec(node, ['hello']).stdout).to include('Hello, world!')
        expect(store.load).not_to have_key('bootstrap_proxy')
        expect(read_node('/tmp/catalog-value')).to eq('first')
        expect(load_count(server)).to eq(1)
        checkpoint = store.load.dig('control_plane', 'environment_cache')
        measure('unchanged') { app.nodes.puppet(name: 'cache-node') }
        expect(load_count(server)).to eq(1)
        expect(store.load.dig('control_plane', 'environment_cache')).to eq(checkpoint)
        write_function('changed')
        measure('changed') { app.nodes.puppet(name: 'cache-node') }
        expect(read_node('/tmp/catalog-value')).to eq('changed')
        expect(load_count(server)).to eq(2)
        expect(service('server').fetch('id')).to eq(server.fetch('id'))
        expect(app.infrastructure.up.changed).to be(false)
        verify_apt
      end

      def write_function(value)
        project.join('modules/cache_fixture/lib/puppet/functions/cache_fixture/value.rb').write(<<~RUBY)
          File.open('/tmp/empeira-code-loads', 'a') { |file| file.puts('loaded') }
          Puppet::Functions.create_function(:'cache_fixture::value') do
            def value
              '#{value}'
            end
          end
        RUBY
      end

      def service(key)
        runtime.inspect_service(Empeira::Services::Definition.new(key: key, workspace: app.context.workspace))
      end

      def node
        runtime.inspect_service(Empeira::Node::Definition.new(hostname: 'cache-node', workspace: app.context.workspace))
      end

      def read_node(path)
        runtime.service_exec(node, ['cat', path]).stdout
      end

      def load_count(server)
        result = runtime.service_exec(server, %w[cat /tmp/empeira-code-loads])
        expect(result).to be_success
        result.stdout.lines.size
      end

      def measure(label)
        before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
        RSpec.configuration.reporter.message(
          format('%<runtime>s %<phase>s: %<seconds>.2fs (whole node command)',
                 runtime: app.context.container_engine, phase: label, seconds: elapsed)
        )
      end

      # rubocop:disable-next Metrics/AbcSize -- Compare real node sources across the complete retained lifecycle.
      def verify_apt
        sources = read_node('/etc/apt/sources.list.d/ubuntu.sources')
        expect(sources).to include('Types: deb', 'Suites: noble', 'Components: main')
        app.nodes.stop(name: 'cache-node')
        app.nodes.start(name: 'cache-node')
        app.infrastructure.up
        expect(read_node('/etc/apt/sources.list.d/ubuntu.sources')).to eq(sources)
        expect(runtime.service_exec(node, ['hello']).stdout).to include('Hello, world!')
        with_package_proxy { |proxy| verify_unrelated_destination_denied(proxy) }
        expect(store.load).not_to have_key('bootstrap_proxy')
      end

      # rubocop:disable-next Metrics/AbcSize -- Bracket the owned temporary proxy in one locked transaction.
      def with_package_proxy
        proxy = Empeira::Network::BootstrapProxy.new(context: app.context, runtime: runtime, store: store)
        requirements = Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04')
        store.with_lock do
          state = store.load
          begin
            proxy.preflight!(state)
            plan = Empeira::ControlPlane::Plan.new(context: app.context)
            address = node.fetch('networks').fetch(plan.network).fetch('IPAddress')
            proxy.start(state, requirements, source: address)
            yield proxy
          ensure
            proxy.cleanup(state)
          end
        end
      end

      def verify_unrelated_destination_denied(proxy)
        denied = runtime.service_exec(node, ['curl', '--silent', '--fail', '--max-time', '5',
                                             '--proxy', proxy.url, 'https://example.com/'])
        expect(denied).not_to be_success
      end
    end
  end
end
