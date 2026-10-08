# frozen_string_literal: true

require 'open3'

RSpec.describe 'CoreDNS additional resolver forwarding', :integration do
  let(:image) do
    defaults = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
    Empeira::Images::Configuration.reference(defaults.dig('images', 'dns'))
  end
  let(:probe) { 'docker.io/library/busybox:1.37.0' }

  def docker(*arguments)
    stdout, stderr, status = Open3.capture3('docker', *arguments)
    raise "Docker DNS fixture failed: #{stderr}" unless status.success?

    stdout.strip
  end

  def query(name, type, server)
    Open3.capture3('docker', 'run', '--rm', '--network', @network, probe,
                   'nslookup', "-type=#{type}", name, server)
  end

  def start_dns(name, corefile, hosts, extra: [], mount_at: '/fixture')
    directory = File.join(@directory, name)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'Corefile'), corefile)
    File.write(File.join(directory, 'hosts'), hosts)
    container = "#{@network}-#{name}"
    docker('run', '--detach', '--name', container, '--network', @network,
           *extra, '--mount', "type=bind,src=#{directory},dst=#{mount_at},readonly",
           image, '-conf', "#{mount_at}/Corefile")
    @containers << container
    docker('inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', container)
  end

  before do
    skip 'Set EMPEIRA_INTEGRATION=1 for real CoreDNS tests' unless ENV['EMPEIRA_INTEGRATION'] == '1'
    unless system('docker', 'info', out: File::NULL, err: File::NULL)
      required = ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?('docker')
      raise 'Required Docker runtime is unavailable' if required

      skip 'Docker is unavailable'
    end

    docker('pull', image) unless system('docker', 'image', 'inspect', image, out: File::NULL, err: File::NULL)
    docker('pull', probe) unless system('docker', 'image', 'inspect', probe, out: File::NULL, err: File::NULL)
    @network = "empeira-dns-spec-#{SecureRandom.hex(6)}"
    @containers = []
    docker('network', 'create', @network)
    additional_corefile = <<~COREFILE
      .:53 {
        hosts /fixture/hosts
        template IN A fallback.test {
          rcode NXDOMAIN
        }
        template IN A route-fallback.corp.test {
          rcode NXDOMAIN
        }
        template IN AAAA nodata.test {
          rcode NOERROR
        }
      }
    COREFILE
    additional_hosts = <<~HOSTS
      198.51.100.10 hit.test
      198.51.100.11 nodata.test
      198.51.100.12 unknown.empeira.internal
      198.51.100.14 route-hit.corp.test
    HOSTS
    @additional = start_dns('additional', additional_corefile, additional_hosts)
    @upstream = start_dns('upstream', ".:53 {\n  hosts /fixture/hosts\n}\n",
                          "198.51.100.20 hit.test fallback.test\n" \
                          "2001:db8::20 nodata.test\n198.51.100.21 unknown.empeira.internal\n" \
                          "198.51.100.24 route-hit.corp.test route-fallback.corp.test\n")
  end

  after do
    next unless @network

    @containers.reverse_each { |name| system('docker', 'rm', '--force', name, out: File::NULL, err: File::NULL) }
    system('docker', 'network', 'rm', @network, out: File::NULL, err: File::NULL)
  end

  { 'host' => 'resolver.example.test', 'explicit' => :ip }.each do |mode, resolver|
    it "uses #{mode} upstream after additional resolver answers NXDOMAIN or NODATA" do
      additional = resolver == :ip ? @additional : resolver
      upstream = { 'mode' => mode, 'servers' => mode == 'host' ? [] : [@upstream] }
      File.write(File.join(@directory, '.empeira.yaml'),
                 YAML.dump('dns' => { 'additional_resolver' => additional, 'upstream' => upstream }))
      context = Empeira::Application.new(project_path: @directory).context
      files = Empeira::ControlPlane::Files.new(context: context)
      files.prepare(upstreams: [@upstream], routes: { 'corp.test' => [@upstream] })
      File.write(files.path('hosts'), "198.51.100.30 server.empeira.internal\n")
      extra = resolver == :ip ? [] : ['--add-host', "resolver.example.test:#{@additional}"]
      server = start_dns('empeira', File.read(files.path('Corefile')),
                         File.read(files.path('hosts')), extra: extra, mount_at: '/empeira')

      hit, = query('hit.test', 'A', server)
      expect(hit).to include('198.51.100.10')
      expect(hit).not_to include('198.51.100.20')
      fallback, = query('fallback.test', 'A', server)
      expect(fallback).to include('198.51.100.20')
      nodata, = query('nodata.test', 'AAAA', server)
      expect(nodata).to include('2001:db8::20')
      route_hit, = query('route-hit.corp.test', 'A', server)
      expect(route_hit).to include('198.51.100.14')
      route_fallback, = query('route-fallback.corp.test', 'A', server)
      expect(route_fallback).to include('198.51.100.24')
      internal, = query('server.empeira.internal', 'A', server)
      expect(internal).to include('198.51.100.30')
      _, _, missing = query('unknown.empeira.internal', 'A', server)
      expect(missing).not_to be_success
    end
  end

  it 'reloads the full Corefile with SIGUSR1 after starting with only the existing upstream' do
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('dns' => { 'additional_resolver' => 'resolver.example.test',
                                    'upstream' => { 'mode' => 'explicit', 'servers' => [@upstream] } }))
    context = Empeira::Application.new(project_path: @directory).context
    files = Empeira::ControlPlane::Files.new(context: context)
    inputs = { upstreams: [@upstream], routes: {} }
    files.prepare(**inputs, bootstrap: true)
    hosts = "198.51.100.30 server.empeira.internal\n"
    server = start_dns('reload', File.read(files.path('Corefile')), hosts,
                       extra: ['--add-host', "resolver.example.test:#{@additional}"], mount_at: '/empeira')
    before, = query('hit.test', 'A', server)
    expect(before).to include('198.51.100.20')

    files.activate_additional_resolver(**inputs)
    File.write(File.join(@directory, 'reload', 'Corefile'), File.read(files.path('Corefile')))
    docker('kill', '--signal', 'USR1', "#{@network}-reload")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      after, = query('hit.test', 'A', server)
      break if after.include?('198.51.100.10')

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise 'CoreDNS did not reload the activated additional resolver'
      end

      sleep 2
    end
    expect(docker('inspect', '--format', '{{.State.Running}}', "#{@network}-reload")).to eq('true')
  end
end
