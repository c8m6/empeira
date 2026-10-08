# frozen_string_literal: true

require 'shellwords'

module SharedNetworkProof
  class PodmanMachine
    attr_reader :commands, :machine

    def initialize(commands:, machine:)
      @commands = commands
      @machine = machine
    end

    def run(*, **)
      commands.run('podman', '--connection', machine, *, **)
    end

    def check
      info = JSON.parse(run('info', '--format', 'json'))
      unless info.dig('host', 'security', 'rootless') && info.dig('host', 'networkBackend') == 'netavark' &&
             info.dig('host', 'arch') == 'arm64'
        raise Failure, 'Requires running arm64 rootless Podman Machine with Netavark'
      end

      puts "Podman Machine #{machine}: #{info.fetch('version').fetch('Version')} rootless Netavark"
    end

    def namespace(*)
      commands.run(*namespace_command(*))
    end

    def namespace_command(*)
      ['podman', 'machine', 'ssh', machine, Shellwords.join(['podman', 'unshare', '--rootless-netns', *])]
    end

    def network_options(bridge)
      ['--disable-dns', '--interface-name', bridge]
    end

    def network_id(observed)
      observed.fetch('id')
    end

    def internal?(observed)
      observed['internal'] && observed['driver'] == 'bridge'
    end

    def peer_command(topology, _name, index)
      verify_binary(topology.assets.path('adapter'))
      namespace_command(topology.assets.path('adapter'), 'tap', "et#{topology.token[0, 9]}#{index}", topology.bridge)
    end

    private

    def verify_binary(path)
      observed = commands.run('podman', 'machine', 'ssh', machine, Shellwords.join(['sha256sum', path])).split.first
      return if observed == Digest::SHA256.file(path).hexdigest

      raise Failure, 'Machine must see the reviewed helper at its canonical host path; shared mount verification failed'
    end
  end

  class DockerDesktop
    attr_reader :commands

    def initialize(commands:)
      @commands = commands
    end

    def run(*, **)
      commands.run('docker', *, **)
    end

    def check
      info = JSON.parse(run('info', '--format', '{{json .}}'))
      unless info['OperatingSystem'].include?('Docker Desktop') && info['Architecture'] == 'aarch64'
        raise Failure, 'Requires a running arm64 Docker Desktop engine'
      end

      puts "Docker Desktop: engine #{info.fetch('ServerVersion')} arm64"
    end

    def network_options(bridge)
      ['--opt', "com.docker.network.bridge.name=#{bridge}",
       '--opt', 'com.docker.network.bridge.gateway_mode_ipv4=isolated']
    end

    def network_id(observed)
      observed.fetch('Id')
    end

    def internal?(observed)
      observed['Internal'] && observed['Driver'] == 'bridge'
    end

    def peer_command(topology, _name, index)
      unless topology.containers.key?('adapter')
        topology.start_probe('adapter', "#{topology.prefix}.140", capabilities: ['NET_ADMIN'],
                                                                  devices: ['/dev/net/tun'])
        run('exec', topology.containers.fetch('adapter'), '/adapter', 'bridge', 'proofbr', 'eth0')
      end
      ['docker', 'exec', '-i', topology.containers.fetch('adapter'), '/adapter', 'tap', "prooftap#{index}", 'proofbr']
    end
  end
end
