# frozen_string_literal: true

# rubocop:disable-next Metrics/ModuleLength -- Shared wire fixtures and production transports for both real runtimes.
module NetworkRedirectFixture
  HTTP_SERVER = <<~'RUBY'
    require 'socket'
    require 'json'
    ARGV.map(&:to_i).map do |port|
      server = TCPServer.new('0.0.0.0', port)
      Thread.new do
        loop do
          client = server.accept
          File.open('/tmp/redirect-requests', 'a') { |file| file.puts('connection') }
          Thread.new(client) do |socket|
            while (line = socket.gets)
              method, path = line.split
              headers = {}
              while (header = socket.gets) && header != "\r\n"
                key, value = header.split(':', 2)
                headers[key.downcase] = value.strip
              end
              body = socket.read(headers.fetch('content-length', '0').to_i)
              response = JSON.generate(method: method, path: path, headers: headers, body: body,
                                       port: port, reply: 'r' * 65_536)
              socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{response.bytesize}\r\n\r\n#{response}")
            end
          rescue IOError, SystemCallError
            nil
          ensure
            socket.close
          end
        end
      end
    end.each(&:join)
  RUBY

  HELD_CLIENT = <<~'RUBY'
    require 'socket'
    require 'timeout'
    host, port, prefix, expected = ARGV
    socket = Socket.tcp(host, port.to_i, connect_timeout: 5)
    at_exit { socket.close }
    read_reply = lambda do
      socket.write("GET /held HTTP/1.1\r\nHost: #{host}\r\n\r\n")
      raise 'Missing HTTP reply' unless socket.gets.include?('200 OK')
      length = nil
      while (line = socket.gets) && line != "\r\n"
        length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
      end
      raise 'Incomplete HTTP reply' unless socket.read(length).bytesize == length
    end
    Timeout.timeout(10) { read_reply.call }
    File.write("#{prefix}-ready", 'ready')
    Timeout.timeout(360) { sleep 0.1 until File.exist?("#{prefix}-release") }
    begin
      Timeout.timeout(3) { read_reply.call }
      abort 'Stale redirected connection survived' unless expected == 'preserved'
    rescue Timeout::Error, IOError, SystemCallError, NoMethodError
      abort 'Unchanged redirected connection was lost' if expected == 'preserved'
    end
    puts expected
  RUBY

  def redirect_app
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                 environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def redirect_state
    Empeira::Infrastructure::Store.new(context: @app.context).load
  end

  def reconcile_redirects
    document = JSON.parse(JSON.generate(@config))
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(document))
    @app = redirect_app
    @app.infrastructure.up
  end

  def redirect_definition(key)
    Empeira::ControlPlane::Plan.new(context: @app.context).definitions.fetch(key)
  end

  def redirect_service(key)
    @runtime.inspect_service(redirect_definition(key),
                             expected_id: redirect_state.dig('control_plane', 'services', key, 'id'))
  end

  # rubocop:disable-next Metrics/AbcSize -- Exercise public providers and the server's native transport.
  def redirect_command(source, arguments)
    if source == 'vm'
      cloud = Empeira::VM::CloudInit.new(context: @app.context, runner: @app.runner)
      ssh = Empeira::VM::SSH.new(context: @app.context, runner: @app.runner, cloud_init: cloud)
      ssh.run(redirect_state.fetch('nodes').fetch('vm-redirect'), arguments)
    else
      resource = if source == 'container'
                   record = redirect_state.fetch('nodes').fetch('container-redirect')
                   definition = Empeira::Node::Definition.new(hostname: record.fetch('hostname'),
                                                              workspace: @app.context.workspace)
                   @runtime.inspect_service(definition, expected_id: record.fetch('id'))
                 else
                   redirect_service(source)
                 end
      @runtime.service_exec(resource, arguments, timeout: 420)
    end
  end

  def redirect_sources
    %w[server api-compat container] + (ENV['EMPEIRA_REDIRECT_VM'] == '1' ? ['vm'] : [])
  end

  # rubocop:disable-next Metrics/AbcSize -- Assert complete wire data through every production transport.
  def check_redirect(ip, source_port: 8080, target_port: 8081)
    redirect_sources.each do |source|
      command = ['curl', '--noproxy', '*', '--fail', '--max-time', '5', '-X', 'DELETE',
                 '-H', 'X-Redirect-Test: literal', '--data-binary', '{"zone":"test.example.net"}',
                 "http://#{ip}:#{source_port}/api/test.example.net?tag=one"]
      result = redirect_command(source, command)
      expect(result).to be_success, "#{source}: #{result.stderr}"
      response = JSON.parse(result.stdout)
      expect(response).to include('method' => 'DELETE', 'path' => '/api/test.example.net?tag=one',
                                  'body' => '{"zone":"test.example.net"}', 'port' => target_port)
      expect(response.fetch('reply')).to eq('r' * 65_536)
      headers = { 'host' => "#{ip}:#{source_port}", 'x-redirect-test' => 'literal' }
      expect(response.fetch('headers')).to include(headers)
    end
  end

  def check_redirect_denied(ip, port = 8080)
    redirect_sources.reject { |source| source == 'api-compat' }.each do |source|
      command = ['curl', '--noproxy', '*', '--max-time', '2', "http://#{ip}:#{port}/forbidden"]
      result = redirect_command(source, command)
      expect(result).not_to be_success, "#{source}: unexpected access to #{ip}:#{port}"
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Own the off-workspace canary and verify its network attachment.
  def external_canary
    plan = Empeira::ControlPlane::Plan.new(context: @app.context)
    egress = Empeira::Network::Egress.new(workspace: @app.context.workspace, policy: Empeira::Network::Policy.new)
    @canary_definition = Empeira::Services::Definition.new(key: 'redirect-canary', workspace: @app.context.workspace,
                                                           image: @fixture_image, network: egress.backend_name,
                                                           memory: 64, entrypoint: '/usr/local/bin/ruby',
                                                           command: ['-e', HTTP_SERVER, '8080'])
    @canary = @runtime.create_service(@canary_definition)
    @runtime.start_service(@canary)
    resource = @runtime.inspect_service(@canary_definition, expected_id: @canary.fetch('id'))
    expect(resource.fetch('networks')).not_to have_key(plan.network)
    resource.dig('networks', egress.backend_name, 'IPAddress')
  end

  def expect_canary_untouched
    code = 'abort "Original external endpoint was contacted" if File.exist?(ARGV[0]) && File.size(ARGV[0]).positive?'
    result = @runtime.service_exec(@canary, ['/usr/local/bin/ruby', '-e', code, '/tmp/redirect-requests'])
    expect(result).to be_success, result.stderr
  end

  # rubocop:disable-next Metrics/AbcSize -- Complete VM preflight before any fixture image or infrastructure mutation.
  def prepare_redirect_project
    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), "notify { 'network-redirect-node': }\n")
    @config = { 'puppetdb' => { 'enabled' => false } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
    @app = redirect_app
    @runtime = Empeira::Runtime.registry.build(engine, context: @app.context, runner: @app.runner)
    @runtime.check_available!
    Empeira::VM.registry.build('qemu', context: @app.context, runner: @app.runner).preflight! if
      ENV['EMPEIRA_REDIRECT_VM'] == '1'
    prepare_redirect_service
  end

  def prepare_redirect_service
    prepare_redirect_image
    repository, _, tag = @fixture_image.rpartition(':')
    service = { 'name' => 'api-compat', 'image' => { 'repository' => repository, 'tag' => tag },
                'command' => ['-e', HTTP_SERVER, '8081', '8082'] }
    @config['containers'] = { 'additional' => [service] }
    reconcile_redirects
  end

  def prepare_redirect_image
    artifact = Empeira::ControlPlane::Plan.new(context: @app.context).gateway_artifact
    @runtime.ensure_image(artifact.fetch(:image), recipe: artifact.fetch(:recipe), files: artifact.fetch(:files))
    recipe = "FROM #{artifact.fetch(:image)}\nRUN apk add --no-cache curl\nENTRYPOINT [\"/usr/local/bin/ruby\"]\n"
    @fixture_image = Empeira::Images::Configuration.local_image(recipe, purpose: 'redirect-fixture')
    @runtime.ensure_image(@fixture_image, recipe: recipe, files: {})
  end

  def rule(ip, source_port: 8080, target_port: 8081)
    { 'from' => { 'ip' => ip, 'port' => source_port }, 'to' => { 'service' => 'api-compat', 'port' => target_port } }
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Coordinate a real open socket across one reconcile.
  def hold_connection(ip, expected:)
    prefix = "/tmp/redirect-#{SecureRandom.hex(8)}"
    thread = Thread.new do
      redirect_command('container',
                       [Empeira::Node::Certificates::RUBY, '-e', HELD_CLIENT, ip, '8080', prefix, expected])
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until redirect_command('container', ['test', '-f', "#{prefix}-ready"]).success?
      raise "Held redirect client failed: #{thread.value.stderr}" unless thread.alive?
      raise 'Held redirect client did not become ready' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    yield
    expect(redirect_command('container', ['touch', "#{prefix}-release"])).to be_success
    result = thread.value
    expect(result).to be_success, result.stderr
    expect(result.stdout.strip).to eq(expected)
  end

  # rubocop:disable-next Metrics/AbcSize -- Force an observed IP change without touching unrelated services or nodes.
  def recreate_redirect_target
    target = redirect_service('api-compat')
    network = redirect_definition('api-compat').options.fetch('network')
    old_ip = target.dig('networks', network, 'IPAddress')
    @runtime.remove_service(redirect_definition('api-compat'), expected_id: target.fetch('id'))
    check_redirect_denied(@original_ip)
    reserve_redirect_address(network, old_ip)
    reconcile_redirects
    replacement = redirect_service('api-compat')
    expect(replacement.fetch('id')).not_to eq(target.fetch('id'))
    expect(replacement.dig('networks', redirect_definition('api-compat').options.fetch('network'),
                           'IPAddress')).not_to eq(old_ip)
  end

  def reserve_redirect_address(network, ip)
    @reservation_definition = Empeira::Services::Definition.new(
      key: 'redirect-reservation', workspace: @app.context.workspace, image: @fixture_image, network: network,
      memory: 32, runtime_ip: ip, entrypoint: 'sleep', command: ['infinity']
    )
    @reservation = @runtime.create_service(@reservation_definition)
    @runtime.start_service(@reservation)
  end
end
