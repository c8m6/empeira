# frozen_string_literal: true

require_relative 'routes'

module SharedNetworkProof
  module Resources
    private

    def attempt(errors)
      yield
    rescue StandardError => e
      errors << e.message
    end

    def finish_cleanup(errors)
      raise Failure, "Proof cleanup incomplete: #{errors.join('; ')}; private logs: #{directory}" unless errors.empty?

      FileUtils.remove_entry_secure(directory)
      puts 'PASS cleanup: owned guests, TAPs, containers, networks and control sockets removed'
    end

    def create_network(name, subnet, bridge: nil, range: nil)
      routes = JSON.parse(@commands.namespace('ip', '-j', '-4', 'route', 'show'))
      Routes.reject_overlap!(routes, subnet)

      options = ['--internal', '--disable-dns', '--subnet', subnet, '--label', "#{Ownership::LABEL}=#{@token}"]
      options += ['--interface-name', bridge] if bridge
      options += ['--ip-range', range] if range
      @commands.podman('network', 'create', *options, name)
      record_network(name)
    end

    def record_network(name)
      observed = JSON.parse(@commands.podman('network', 'inspect', name)).first
      id = observed.fetch('id')
      Ownership.verify!(observed, id: id, token: @token)
      @networks << { id: id, name: name }
      raise Failure, 'Expected internal bridge network' unless observed['internal'] && observed['driver'] == 'bridge'
    end

    def start_container(name)
      # Podman 4.9 otherwise changes the MAC even on stop/start of the same container.
      # Allocate once per instance, never derive a replacement's MAC from its name or IP.
      mac = "02:#{SecureRandom.hex(5).scan(/../).join(':')}"
      options = ['--network', "#{@network}:ip=#{addresses.fetch(name)}", '--mac-address', mac]
      run_container(name, options, @assets.image, ['daemon', name])
      wait_container(name)
    end

    def start_canary
      outside = "#{@network}-outside"
      lan = "#{@network}-lan"
      create_network(outside, "#{@outside.sub(/\.2\z/, '.0')}/24")
      create_network(lan, "#{@lan.sub(/\.2\z/, '.0')}/24")
      run_container('canary', ['--network', "#{outside}:ip=#{@outside}", '--network', "#{lan}:ip=#{@lan}"],
                    @assets.image, %w[daemon canary])
      wait_container('canary')
    end

    def run_container(name, network_options, image, arguments)
      # Real WSL2 validation requires the official CoreDNS image's runtime/file capabilities.
      # Synthetic probes keep both restrictions; CoreDNS retains rootless Podman defaults.
      security = name == 'dns' ? [] : ['--cap-drop=all', '--security-opt=no-new-privileges']
      id = @commands.podman('create', '--name', "#{@network}-#{name}", '--label', "#{Ownership::LABEL}=#{@token}",
                            *security, '--read-only', '--tmpfs', '/tmp',
                            '--sysctl', 'net.ipv6.conf.all.disable_ipv6=1',
                            '--sysctl', 'net.ipv4.ip_unprivileged_port_start=0',
                            *network_options, image, *arguments).strip
      containers[name] = id
      observed = JSON.parse(@commands.podman('inspect', id)).first
      Ownership.verify!(observed, id: id, token: @token)
      raise Failure, 'Proof must not publish application ports' unless observed.dig('HostConfig',
                                                                                    'PortBindings').to_h.empty?

      @commands.podman('start', id)
    end

    def wait_container(name)
      Timeout.timeout(15) do
        loop do
          return if request(name, op: 'info')['tcp']
        rescue Failure
          sleep 0.2
        end
      end
    end

    def remove_container(name)
      id = containers.fetch(name)
      observed = JSON.parse(@commands.podman('inspect', id)).first
      Ownership.verify!(observed, id: id, token: @token)
      @commands.podman('rm', '--force', id)
      containers.delete(name)
    end

    def remove_tap(tap)
      observed = JSON.parse(@commands.namespace('ip', '-j', 'link', 'show', 'dev', tap)).first
      raise Failure, "TAP #{tap} ownership mismatch" unless observed['ifalias'] == "#{@token}:#{tap}"

      @commands.namespace('ip', 'link', 'delete', 'dev', tap)
    end

    def remove_network(entry)
      id = entry.fetch(:id)
      observed = JSON.parse(@commands.podman('network', 'inspect', id)).first
      Ownership.verify!(observed, id: id, token: @token)
      @commands.podman('network', 'rm', id)
    end
  end
end
