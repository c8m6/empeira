# frozen_string_literal: true

require 'net/http'

# Test-only loopback Distribution registry. No user auth/TLS configuration is changed.
# rubocop:disable-next Metrics/ClassLength -- One owned registry fixture covers transport, native login and cleanup.
class ImageRegistryFixture
  attr_reader :host, :calls, :image

  def initialize(runtime:, runner:, directory:, auth: false)
    @runtime = runtime
    @runner = runner
    @directory = directory
    @token = SecureRandom.hex(16)
    @calls = []
    @identities = []
    @auth = auth
  end

  # rubocop:disable-next Metrics/AbcSize -- Start, locate and configure only this owned fixture registry.
  def start
    @runtime.ensure_image('docker.io/library/registry:3')
    @container = command(['run', '-d', '--label', "io.empeira.fixture=#{@token}",
                          '-p', '127.0.0.1::5000', *authentication_options,
                          'docker.io/library/registry:3']).stdout.strip
    data = JSON.parse(command(['inspect', @container]).stdout).first
    port = data.fetch('NetworkSettings').fetch('Ports').fetch('5000/tcp').first.fetch('HostPort')
    @host = "127.0.0.1:#{port}"
    @image = "#{host}/library/empeira-fixture:latest"
    @registry_config = File.join(@directory, 'registries.conf')
    File.write(@registry_config, "[[registry]]\nlocation = \"#{host}\"\ninsecure = true\n")
    wait_ready
    self
  end

  # Only this synthetic HTTP registry is insecure, through explicit fixture arguments.
  # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Narrow transport overrides for the two native CLIs.
  def arguments(arguments)
    @calls << arguments
    return arguments unless arguments.join(' ').include?(host) ||
                            (@runtime.name == 'podman' && arguments.take(2) == %w[manifest inspect])

    if @runtime.name == 'docker' && arguments.take(2) == %w[manifest inspect]
      [*arguments.take(2), '--insecure', *arguments.drop(2)]
    elsif @runtime.name == 'podman' && [%w[manifest add], %w[manifest inspect]].include?(arguments.take(2))
      [*arguments.take(2), '--tls-verify=false', *arguments.drop(2)]
    elsif @runtime.name == 'podman' && %w[pull push build].include?(arguments.first)
      [arguments.first, '--tls-verify=false', *arguments.drop(1)]
    else
      arguments
    end
  end

  def environment
    directory = File.join(@directory, 'native-auth')
    FileUtils.mkdir_p(directory)
    if @runtime.name == 'podman'
      { 'CONTAINERS_REGISTRIES_CONF' => @registry_config, 'REGISTRY_AUTH_FILE' => File.join(directory, 'auth.json') }
    else
      { 'DOCKER_CONFIG' => directory }
    end
  end

  def login
    Tempfile.create('synthetic-registry-password', @directory) do |input|
      input.write("empeira-fixture-only\n")
      input.rewind
      options = @runtime.name == 'podman' ? ['--tls-verify=false'] : []
      result = @runner.buffered(@runtime.name, arguments: ['login', *options, '--username', 'fixture',
                                                           '--password-stdin', host],
                                               environment: environment, input: input)
      raise 'Synthetic native login failed' unless result.success?
    end
  end

  def logout
    command(['logout', host])
  end

  def publish(value)
    path = File.join(@directory, 'fixture-context')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'value'), value)
    File.write(File.join(path, 'Containerfile'), "FROM scratch\nCOPY value /value\n")
    command(['build', '--label', "io.empeira.fixture=#{@token}", '-t', image,
             '-f', File.join(path, 'Containerfile'), path])
    @identities << @runtime.image_id(image)
    command(['push', image])
  end

  def forget_tag
    command(['image', 'rm', image])
  end

  def restore(identity)
    command(['tag', identity, image])
  end

  def counts
    { pulls: calls.count { |args| args.first == 'pull' },
      builds: calls.count { |args| args.first == 'build' },
      metadata: calls.count do |args|
        args.take(2) == (@runtime.name == 'docker' ? %w[manifest inspect] : %w[manifest add])
      end }
  end

  # rubocop:disable-next Metrics/AbcSize -- Validate ownership before deleting each fixture resource.
  def close
    if @container
      data = JSON.parse(command(['inspect', @container]).stdout).first
      raise 'Foreign fixture container' unless data.dig('Config', 'Labels', 'io.empeira.fixture') == @token

      command(['rm', '-f', '-v', @container])
    end
    @identities.uniq.each do |identity|
      result = @runner.run(@runtime.name, arguments: ['image', 'inspect', identity], timeout: 30)
      next unless result.success?

      data = JSON.parse(result.stdout).first
      raise 'Foreign fixture image' unless data.dig('Config', 'Labels', 'io.empeira.fixture') == @token

      command(['image', 'rm', '-f', identity])
    end
  end

  private

  def authentication_options
    return [] unless @auth

    path = File.join(@directory, 'registry.htpasswd')
    # Generated synthetic bcrypt fixture; no real account or credentials.
    File.write(path, "fixture:$2a$05$abcdefghijklmnopqrstuu1genMO2BBRMaDcETcONJlJe6JGzxokC\n")
    ['--mount', "type=bind,src=#{path},dst=/auth/htpasswd,readonly",
     '--env', 'REGISTRY_AUTH=htpasswd', '--env', 'REGISTRY_AUTH_HTPASSWD_REALM=synthetic',
     '--env', 'REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd']
  end

  def command(arguments)
    @runtime.update_command(arguments, operation: 'synthetic registry fixture')
  end

  def wait_ready
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    uri = URI("http://#{host}/v2/")
    loop do
      begin
        return if Net::HTTP.start(uri.host, uri.port, nil, open_timeout: 1, read_timeout: 1) do |http|
          http.get(uri.path).code == (@auth ? '401' : '200')
        end
      rescue SystemCallError, IOError
        # Container process startup is asynchronous.
      end
      raise 'Synthetic registry did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end
end
