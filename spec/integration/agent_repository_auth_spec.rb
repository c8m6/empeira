# frozen_string_literal: true

require_relative '../support/apt_repository'
require_relative '../support/agent_login_terminal'

RSpec.describe 'Real APT helper authentication', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
      let(:target) { Empeira::Agent::Target.new(os: 'ubuntu', release: '24.04', architecture: runtime.architecture) }
      let(:input) { AgentLoginTerminal.new("yes\n#{credentials.first}\n#{credentials.last}\n") }
      let(:output) { AgentLoginTerminal.new }
      let(:credentials) { ['fixture-user', 'fixture-ü-"literal"-\\password'] }
      let(:calls) { [] }

      before do
        skip 'Set EMPEIRA_INTEGRATION=agent-auth for the signed HTTPS APT fixture' unless
          ENV['EMPEIRA_INTEGRATION'] == 'agent-auth'
        skip "Select #{engine} with EMPEIRA_REQUIRED_RUNTIMES" unless
          ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', engine).split(',').include?(engine)

        runtime.check_available!
      end

      after do
        @fixture&.close
        @proxy_environment&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      # rubocop:disable-next Metrics/AbcSize -- Resolve the reviewed helper image against the native target.
      def helper_image
        request = Struct.new(:os, :version).new(target.os, target.release)
        image = Empeira::Node::Image.new(config: app.context.configuration, request: request,
                                         architecture: target.architecture)
        runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
        image.reference
      end

      def clear_proxy_environment
        @proxy_environment = %w[HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy ALL_PROXY all_proxy]
                             .to_h { |key| [key, ENV.delete(key)] }
      end

      def host_address(resource)
        hostname = runtime.name == 'podman' ? 'host.containers.internal' : 'host.docker.internal'
        result = runtime.service_exec(resource, ['getent', 'ahostsv4', hostname], timeout: 10)
        return result.stdout.split.first if result.success?

        routes = runtime.service_exec(resource, ['ip', '-j', 'route', 'show', 'default'], timeout: 10)
        raise 'Cannot locate the local synthetic repository from the helper' unless routes.success?

        JSON.parse(routes.stdout).first.fetch('gateway')
      end

      def trust_fixture(resource)
        certificate = Pathname(@directory).join('fixture-ca.crt')
        certificate.write(@fixture.http.certificate.to_pem)
        runtime.copy_to(resource, certificate, '/usr/local/share/ca-certificates/empeira-fixture.crt')
        expect(runtime.service_exec(resource, ['update-ca-certificates'], timeout: 30)).to be_success
        trust_host_transport
      end

      def trust_host_transport
        store = OpenSSL::X509::Store.new
        store.add_cert(@fixture.http.certificate)
        allow(Net::HTTP).to receive(:start).and_wrap_original do |method, host, port, **options, &block|
          method.call(host, port, nil, **options, cert_store: store, &block)
        end
      end

      def resolver(resource, authentication, download)
        execute = lambda do |arguments|
          result = runtime.service_exec(resource, arguments, timeout: 60)
          calls << [arguments, result]
          result
        end
        copy = lambda do |path, destination, mode|
          runtime.copy_to(resource, path, destination)
          expect(execute.call(['chmod', mode, destination])).to be_success
        end
        Empeira::Node::AgentRepository.new(source: @fixture.source, package: 'synthetic-agent', version: '1.2.3',
                                           target: target, execute: execute, copy: copy, download: download,
                                           authentication: authentication, directory: @directory)
      end

      def verify_apt_configuration(resource, acquisition)
        options = acquisition.send(:apt_options)
        result = runtime.service_exec(resource, ['apt-config', *options, 'dump'], timeout: 10)
        expect(result).to be_success
        expect(result.stdout).to include('Dir::Etc "etc/apt";', 'Dir::Etc::netrcparts "auth.conf.d";')
        verify_auth_file(resource)
      end

      # rubocop:disable-next Metrics/AbcSize -- Assert private file modes and exact tokens without exposing their content.
      def verify_auth_file(resource)
        path = Empeira::Node::AgentRepository::AUTH_PATH
        content = runtime.service_exec(resource, ['cat', path], timeout: 10).stdout
        expected = "machine #{URI(@fixture.source.fetch('url')).origin}\n" \
                   "login #{credentials.first}\npassword #{credentials.last}\n"
        expect(content.b == expected.b).to be(true), 'APT authentication tokens must preserve exact credential bytes'
        expect(runtime.service_exec(resource, ['stat', '-c', '%a', path], timeout: 10).stdout.strip).to eq('600')
      end

      it 'retries metadata 401 once after interactive login, then downloads the package with the same credentials' do
        image = helper_image
        clear_proxy_environment
        runtime.with_agent_helper(image: image) do |resource|
          @fixture = APTRepositoryFixture.new(runner: app.runner, directory: @directory,
                                              address: host_address(resource), architecture: target.architecture,
                                              credentials: credentials)
          trust_fixture(resource)
          authentication = Empeira::Agent::Authentication.new(url: @fixture.source.fetch('url'), input: input,
                                                              output: output)
          download = Empeira::Agent::Download.new(authentication: authentication)
          acquisition = resolver(resource, authentication, download)
          selected = acquisition.resolve
          verify_apt_configuration(resource, acquisition)
          metadata = calls.select { |arguments, _result| arguments.first == 'apt-get' && arguments.include?('update') }
          expect(metadata.map { |_arguments, result| result.success? }).to eq([false, true])
          expect(output.string.scan('Username:').size).to eq(1)
          events = @fixture.events.select { |event| event.fetch(:path).end_with?('/InRelease') }
          expect(events.map { |event| event.fetch(:code) }).to eq(%w[401 200])
          path = Pathname(@directory).join('agent.deb')
          download.fetch(selected.fetch('url'), path, sha256: selected.fetch('sha256'))
          expect(path.read).to eq(@fixture.package)
          expect(@fixture.events.last).to include(code: '200', authenticated: true, path: '/apt/pool/agent.deb')
          text = calls.map { |arguments, result| [arguments.join(' '), result.stderr] }.flatten.join("\n")
          expect(credentials.any? { |value| text.include?(value) }).to be(false)
        end
      end
    end
  end
end
