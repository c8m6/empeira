# frozen_string_literal: true

require 'net/http'
require 'openssl'

RSpec.describe 'Real browser integration', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { File.join(@directory, 'control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        unless ENV['EMPEIRA_BROWSER_INTEGRATION'] == '1'
          skip 'Set EMPEIRA_BROWSER_INTEGRATION=1 for the full Chromium image'
        end
        initialize_project(project)
        configuration = { 'puppetdb' => { 'enabled' => false },
                          'browser' => { 'start_url' => 'http://unavailable.empeira.internal:5000' },
                          'containers' => { 'additional' => [helper_definition] } }
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(configuration))
        runtime.check_available!
        @available = true
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do |example|
        diagnose_browser if @available && example.exception
      ensure
        app.infrastructure.destroy if @available
      end

      it 'serves its loopback UI, resolves internal services, blocks direct Internet and cleans up' do
        app.infrastructure.up
        persistent = Empeira::Infrastructure::Store.new(context: app.context)
        state_before = JSON.parse(JSON.generate(persistent.load))
        url = app.infrastructure.browser
        expect(url).to match(%r{\Ahttps://127\.0\.0\.1:\d+/\z})
        wait_for_ui(url)
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        browser_definition = Empeira::ControlPlane::Browser.new(plan).definitions.fetch('browser')
        browser = runtime.inspect_service(browser_definition)
        expect(browser.fetch('networks').keys).to eq([plan.network])
        expect(browser.fetch('ports')).to be_empty
        # The desktop starts even though the configured page has no running target service.
        start_url = runtime.service_exec(browser, %w[printenv CHROME_CLI])
        expect(start_url).to be_success
        expect(start_url.stdout.strip).to eq('http://unavailable.empeira.internal:5000')
        verify_internal(browser)
        blocked = runtime.service_exec(browser, ['python3', '-c',
                                                 'import socket; socket.create_connection(("1.1.1.1",443),2)'])
        expect(blocked).not_to be_success
        expect(app.infrastructure.browser).to eq(url)
        expect(runtime.inspect_service(browser_definition)['id']).to eq(browser['id'])
        state_after = JSON.parse(JSON.generate(persistent.load))
        state_after.fetch('control_plane').fetch('services').delete('browser')
        state_after.fetch('control_plane').fetch('services').delete('browser-ui')
        expect(state_after).to eq(state_before)
        app.infrastructure.down
        expect(runtime.inspect_service(browser_definition)).to be_nil
        expect(runtime.inspect_service(Empeira::Services::Definition.new(key: 'browser-ui',
                                                                         workspace: app.context.workspace)))
          .to be_nil
      end

      def diagnose_browser
        %w[browser browser-ui].each do |key|
          identity = Empeira::Services::Definition.new(key: key, workspace: app.context.workspace)
          resource = runtime.inspect_service(identity)
          next unless resource

          browser_diagnostic(key, resource)
        end
      end

      def browser_diagnostic(key, resource)
        warn "#{key}: state=#{resource['state']} networks=#{resource['networks'].keys}"
        output = app.runner.run(engine_name, arguments: ['logs', '--tail', '100', resource.fetch('id')], timeout: 10)
        warn output.stdout, output.stderr
        probe = runtime.service_exec(resource, ['cat', '/etc/resolv.conf'])
        warn probe.stdout
      end

      def engine_name
        app.context.container_engine
      end

      def helper_definition
        { 'name' => 'web-helper', 'image' => { 'repository' => 'docker.io/library/busybox', 'tag' => '1.37.0' },
          'command' => ['httpd', '-f', '-p', '8080'] }
      end

      def verify_internal(browser)
        code = 'import socket; ' \
               'print(socket.gethostbyname("server.empeira.internal")); ' \
               's=socket.create_connection(("web-helper.empeira.internal",8080),5); ' \
               's.sendall(b"GET / HTTP/1.0\r\n\r\n"); print(s.recv(1024))'
        result = runtime.service_exec(browser, ['python3', '-c', code])
        expect(result).to be_success
        expect(result.stdout).to include('404 Not Found')
      end

      def wait_for_ui(url)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
        loop do
          return if ui_ready?(URI(url))
          raise 'Browser HTTPS UI did not become ready' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 1
        end
      end

      def ui_ready?(uri)
        # Only this synthetic loopback endpoint uses the image's self-signed UI certificate.
        client = Net::HTTP.new(uri.host, uri.port, nil)
        client.use_ssl = true
        client.verify_mode = OpenSSL::SSL::VERIFY_NONE
        client.open_timeout = 3
        client.read_timeout = 3
        client.get('/').code == '200'
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
        false
      end
    end
  end
end
