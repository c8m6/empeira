# frozen_string_literal: true

module CoreDNSFixture
  def dns_command(*arguments, **options)
    result = @dns_runner.run('docker', arguments: arguments, timeout: 60, **options)
    raise "CoreDNS fixture failed: #{result.stdout} #{result.stderr}" unless result.success?

    result.stdout.strip
  end

  def prepare_dns_fixture
    @dns_runner = Empeira::Execution::Runner.new
    check_dns_runtime
    @dns_containers = []
    @dns_network = "empeira-rewrites-spec-#{SecureRandom.hex(6)}"
    dns_command('network', 'create', '--internal', @dns_network)
    defaults = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
    @dns_image = Empeira::Images::Configuration.reference(defaults.dig('images', 'dns'))
    @dns_probe_image = 'docker.io/library/busybox:1.37.0'
    @dns_upstream, = start_dns_fixture('upstream', <<~CONFIG, upstream_hosts)
      .:53 {
        hosts /empeira/hosts
        log
      }
    CONFIG
  end

  def check_dns_runtime
    available = @dns_runner.run('docker', arguments: ['info'], timeout: 10).success?
    required = ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?('docker')
    raise 'Required Docker runtime is unavailable' if !available && required

    skip 'Docker is unavailable' unless available
  end

  def upstream_hosts
    "198.51.100.10 ipam.example.net inventory.example.net child.ipam.example.net external.example.net\n" \
      "198.51.100.11 api-layer.empeira.internal unknown.empeira.internal\n"
  end

  def start_dns_fixture(key, corefile, hosts)
    directory = File.join(@directory, key)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'Corefile'), corefile)
    File.write(File.join(directory, 'hosts'), hosts)
    id = dns_command('run', '--detach', '--network', @dns_network,
                     '--mount', "type=bind,src=#{directory},dst=/empeira,readonly", @dns_image,
                     '-conf', '/empeira/Corefile')
    @dns_containers << id
    [dns_command('inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', id), id]
  end

  def rewrite_files(rewrites, additional_resolver: nil, routes: {})
    config = { 'dns' => { 'rewrites' => rewrites,
                          'additional_resolver' => additional_resolver,
                          'upstream' => { 'mode' => 'explicit', 'servers' => [@dns_upstream] } } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    context = Empeira::Application.new(project_path: @directory).context
    Empeira::ControlPlane::Files.new(context: context).tap do |files|
      files.prepare(upstreams: [@dns_upstream], routes: routes)
    end
  end

  def publish_dns_files(files)
    %w[Corefile hosts].each do |name|
      files_content = File.read(files.path(name))
      destination = File.join(@directory, 'managed', name)
      Tempfile.create('dns-fixture-', File.dirname(destination)) do |file|
        file.chmod(0o644)
        file.write(files_content)
        file.flush
        File.rename(file.path, destination)
      end
    end
  end

  def start_dns_client
    @dns_client = dns_command('run', '--detach', '--network', @dns_network,
                              @dns_probe_image, 'sleep', '600')
    @dns_containers << @dns_client
  end

  def dns_query(name, type = 'A')
    @dns_runner.run('docker', arguments: ['exec', @dns_client, 'nslookup', "-type=#{type}", name, @managed_dns],
                              timeout: 10)
  end

  def wait_for_dns
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      result = yield
      return if result
      raise 'CoreDNS did not publish the expected answer' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    end
  end

  def cleanup_dns_fixture
    @dns_containers&.reverse_each { |id| dns_command('rm', '--force', id) }
    dns_command('network', 'rm', @dns_network) if @dns_network
  end
end
