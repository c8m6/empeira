# frozen_string_literal: true

require_relative '../support/proxy_fixture'
require_relative '../support/openvox_view'
require_relative '../support/puppetdb_queries'

# Curl's write-out placeholders are not Ruby format strings.
# rubocop:disable Style/FormatStringToken
RSpec.describe 'Real control-plane integration', :integration do
  include OpenVoxViewFixture
  include PuppetDBQueries

  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:project) { File.join(@directory, 'control') }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=1 for actual container tests' unless ENV['EMPEIRA_INTEGRATION'] == '1'
        initialize_project(project)
        FileUtils.mkdir_p(File.join(project, 'manifests'))
        File.write(File.join(project, '.empeira.yaml'), YAML.dump('containers' => { 'additional' => [openvox_view] }))
        runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do |example|
        next unless ENV['EMPEIRA_INTEGRATION'] == '1'

        if example.exception && (board = service('openvoxview'))
          logs = app.runner.run(app.context.container_engine, arguments: ['logs', '--tail', '60', board.fetch('id')],
                                                              timeout: 10)
          warn logs.stdout, logs.stderr
        end
        @fixture&.stop
        app.infrastructure.destroy if File.directory?(project)
      end

      it 'compiles live code, stores exported resources, and retains CA and data' do
        File.write(File.join(project, 'manifests/site.pp'), "@@notify { 'exported-phase3': }\nnotify { 'live-v1': }\n")
        app.infrastructure.up
        server = service('server')
        expect(compile(server).stdout).to include('live-v1')
        verify_openvox_view
        health = Empeira::ControlPlane::Health.new(runtime: runtime,
                                                   plan: Empeira::ControlPlane::Plan.new(context: app.context))
        expect(runtime.service_exec(server, [*health.http_curl, '--cacert',
                                             '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
                                             'https://puppetdb.empeira.internal:8081/pdb/query/v4/nodes']))
          .to be_success
        %w[puppetdb puppetdb-backend].each do |key|
          expect(service(key).fetch('ports')).to be_empty
        end
        expect(runtime.service_exec(server, [*health.http_curl,
                                             'https://puppetdb-backend.empeira.internal:8081/pdb/query/v4/nodes']))
          .not_to be_success
        expect(runtime.service_exec(server, [*health.http_curl, '--request', 'CONNECT',
                                             'http://puppetdb.empeira.internal:8080/']))
          .not_to be_success
        exported = query_until(server, [*health.http_curl, '--get', '--data-urlencode', 'query=["=","exported",true]',
                                        'http://puppetdb.empeira.internal:8080/pdb/query/v4/resources'])
        expect(exported).to include('exported-phase3')
        File.write(File.join(project, 'manifests/site.pp'), "notify { 'live-v2': }\n")
        app.infrastructure.up
        expect(compile(server).stdout).to include('live-v2')
        ca = runtime.service_exec(server, %w[sha256sum /etc/puppetlabs/puppet/ssl/certs/ca.pem]).stdout
        unauthenticated = runtime.service_exec(server, %w[curl --silent --fail --max-time 5 --noproxy *
                                                          http://puppetdb.empeira.internal:8080/pdb/query/v4/nodes])
        expect(unauthenticated).to be_success
        app.infrastructure.down
        app.infrastructure.up
        expect(runtime.service_exec(service('server'),
                                    %w[sha256sum /etc/puppetlabs/puppet/ssl/certs/ca.pem]).stdout).to eq(ca)
        expect(query_until(service('server'), [*health.http_curl, 'http://puppetdb.empeira.internal:8080/pdb/query/v4/nodes']))
          .to include('server.empeira.internal')
        expect(app.infrastructure.status).to include('Puppetdb' => 'running')
        expect(compile(service('server')).stdout).to include('live-v2')
      end

      it 'allows selected HTTP and HTTPS domains at private IPs while denying other domains and direct egress' do
        @fixture = ProxyFixture.new(app: app, runtime: runtime, directory: @directory)
        @fixture.start
        config = { 'proxy' => { 'enabled' => true,
                                'global' => %w[allowed.test private.test],
                                'rules' => [{ 'hosts' => ['*-web-*'], 'allow' => ['denied.test'] }] },
                   'dns' => { 'upstream' => { 'mode' => 'explicit', 'servers' => [@fixture.dns_address] } } }
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
        configured = Empeira::Application.new(project_path: project, locations: locations,
                                              overrides: { 'runtime' => { 'container_engine' => engine } })
        # Exercise host discovery with a synthetic resolv.conf, then an explicit override.
        host_config = Marshal.load(Marshal.dump(config))
        host_config['dns']['upstream'] = { 'mode' => 'host', 'servers' => [] }
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(host_config))
        resolver_file = File.join(@directory, 'resolv.conf')
        File.write(resolver_file, "nameserver #{@fixture.dns_address}\n")
        reader = Object.new
        reader.define_singleton_method(:read) { |_path| File.read(resolver_file) }
        allow(Empeira::Platform::Resolvers).to receive(:new).and_wrap_original do |constructor, **options|
          constructor.call(**options, platform: Empeira::Platform::Facts.new(host_os: 'linux'), reader: reader)
        end
        current = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine } })
        current.infrastructure.up
        lookup = [Empeira::ControlPlane::Health::RUBY, '-rresolv', '-e',
                  'puts Resolv.getaddress("allowed.test"); puts Resolv.getaddress("server.empeira.internal")']
        addresses = runtime.service_exec(service('server'), lookup).stdout.lines.map(&:strip)
        expect(addresses.size).to eq(2)
        expect(IPAddr.new('10.0.0.0/8')).to include(IPAddr.new(addresses.first))
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
        configured.infrastructure.up
        server = service('server')
        curl = %w[curl --silent --show-error --max-time 10 --proxy http://proxy.empeira.internal:3128 --noproxy
                  localhost]
        allowed = runtime.service_exec(server, [*curl, '--fail', 'http://allowed.test'])
        expect(allowed).to be_success, allowed.stderr
        expect(allowed.stdout).to eq('fixture')
        expect(runtime.service_exec(server, [*curl, '--fail', '--cacert',
                                             '/etc/puppetlabs/code/environments/production/fixture-ca.pem',
                                             'https://allowed.test']).stdout).to eq('fixture')
        expect(runtime.service_exec(server, [*curl, '--fail', 'http://private.test']).stdout).to eq('fixture')
        %w[http https].each do |scheme|
          denied = runtime.service_exec(server, [*curl, '--fail', '--output', '/dev/null',
                                                 '--write-out', '%{http_code}', "#{scheme}://denied.test"])
          expect(denied).not_to be_success
          expect(denied.stderr).to include('403')
          expect(denied.stdout).to eq('403') if scheme == 'http'
        end
        direct = runtime.service_exec(server, %w[curl --silent --fail --max-time 3 --noproxy * http://1.1.1.1])
        expect(direct).not_to be_success
        dns = runtime.service_exec(server, [Empeira::ControlPlane::Health::RUBY, '-rresolv', '-e',
                                            'exit(Resolv.getaddresses("allowed.test").empty? ? 1 : 0)'])
        expect(dns).to be_success
        ids = %w[server puppetdb postgres dns].to_h { |key| [key, service(key).fetch('id')] }
        config['proxy']['global'] << 'also.test'
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
        current = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine } })
        current.infrastructure.up
        expect(ids.transform_values.with_index { |_, index| service(ids.keys[index]).fetch('id') }).to eq(ids)
        expect(configured.infrastructure.status['Server']).to eq('running')
        request = Empeira::Node::RunRequest.from_config(hostname: 'plain-node', provider: 'container',
                                                        config: configured.context.configuration)
        configured.nodes.run(request)
        configured.nodes.run(request.with(hostname: 'lab-web-1-01.test'))
        plain = runtime.inspect_service(Empeira::Node::Definition.new(hostname: 'plain-node',
                                                                      workspace: app.context.workspace))
        online = runtime.inspect_service(Empeira::Node::Definition.new(hostname: 'lab-web-1-01.test',
                                                                       workspace: app.context.workspace))
        expect(runtime.service_exec(plain,
                                    %w[curl --silent --fail --max-time 10 http://allowed.test]).stdout).to eq('fixture')
        denied = runtime.service_exec(plain, [*curl, '--output', '/dev/null', '--write-out', '%{http_code}',
                                              'http://denied.test'])
        expect(denied.stdout).to eq('403')
        expect(runtime.service_exec(online,
                                    %w[curl --silent --fail --max-time 10 http://allowed.test]).stdout).to eq('fixture')
        expect(runtime.service_exec(online,
                                    %w[curl --silent --fail --max-time 10 http://denied.test]).stdout).to eq('fixture')
        expect(runtime.service_exec(server, [*curl, '--fail', 'http://denied.test'])).not_to be_success
        runtime.copy_to(online, @fixture.ca_path, '/tmp/fixture-ca.pem')
        expect(runtime.service_exec(online,
                                    %w[curl --silent --fail --max-time 10 --cacert /tmp/fixture-ca.pem
                                       https://allowed.test]).stdout).to eq('fixture')
        expect(runtime.service_exec(plain,
                                    %w[curl --silent --fail --max-time 3 --noproxy * http://1.1.1.1])).not_to be_success
        configured.nodes.destroy(name: 'lab-web-1-01.test')
        configured.nodes.destroy(name: 'offline-node')
      end

      # rubocop:disable-next Metrics/AbcSize -- Check real helper API access, UI and isolated attachments together.
      def verify_openvox_view
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        %w[puppetdb openvoxview].each do |key|
          expect(service(key).fetch('ports')).to be_empty
          expect(service(key).fetch('networks').keys).to eq([plan.network])
        end
        arguments = %w[curl --silent --fail --location --max-time 5 --noproxy *]
        endpoint = 'http://openvoxview.empeira.internal:5000'
        expect(query_until(service('server'), [*arguments, "#{endpoint}/"])).to include('OpenVox')
        query = [*arguments, '--header', 'Content-Type: application/json',
                 '--data', JSON.generate('Query' => 'nodes[certname] {}'), "#{endpoint}/api/v1/pdb/query"]
        expect(query_until(service('server'), query, containing: 'server.empeira.internal'))
          .to include('server.empeira.internal')
        meta = query_until(service('server'), [*arguments, "#{endpoint}/api/v1/meta"])
        expect(JSON.parse(meta).fetch('Data').fetch('CaEnabled')).to be(false)
        expect(Dir.glob(locations.workspace(app.context.workspace).join('**/*puppetdb-tls*'))).to be_empty
      end

      def service(key)
        definition = Empeira::Services::Definition.new(key: key, workspace: app.context.workspace)
        runtime.inspect_service(definition)
      end

      def compile(server)
        result = runtime.service_exec(server, %w[/opt/puppetlabs/bin/puppet agent --test --noop --server
                                                 server.empeira.internal --certname server.empeira.internal
                                                 --environment production --detailed-exitcodes], timeout: 90)
        expect([0, 2]).to include(result.exit_status), result.stderr
        result
      end
    end
  end
end

# rubocop:enable Style/FormatStringToken
