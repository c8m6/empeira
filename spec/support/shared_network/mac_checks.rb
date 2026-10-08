# frozen_string_literal: true

module SharedNetworkProof
  module MacChecks
    def isolation
      info = request('canary', op: 'info')
      %w[tcp udp].each do |protocol|
        target = "#{@canary_ip}:#{info.fetch(protocol)}"
        request('canary', op: 'probe', proto: protocol, target: target, payload: payload)
        %w[container-a vm-a].each do |source|
          request(source, op: 'blocked', proto: protocol, target: target, payload: payload)
        end
      end
      check_default_route
      puts 'PASS isolation: responding off-network TCP/UDP canary denied; VM forced default route cannot escape'
    end

    def lifecycle
      restart_guest
      restart_container
      matrix
      dns_and_browser
      isolation
      puts 'PASS lifecycle: VM and container stop/start retain node IP/MAC; peers and DNS restored'
      destroy_container
    end

    private

    def destroy_container
      id = containers.fetch('container-b')
      remove_owned('containers', "#{@network}-container-b")
      raise Failure, 'Destroyed container remains' if @runtime.run('ps', '-aq', '--no-trunc').split.include?(id)

      containers.delete('container-b')
      addresses.delete('container-b')
      puts 'PASS destroy: container removed before its fixture lease was released'
    end

    def payload
      ["empeira-macos-proof-#{token}\0\xff".b].pack('m0')
    end

    def start_canary
      @canary_ip = "198.19.#{token[0, 2].to_i(16)}.2"
      network = "#{@network}-outside"
      create_network(network, "#{@canary_ip.sub(/\.2\z/, '.0')}/24", "eo#{token[0, 10]}")
      create_container('canary', @canary_ip, ['--cap-drop=all', '--security-opt=no-new-privileges'],
                       assets.image, %w[daemon canary], network: network)
      wait_probe('canary')
    end

    def check_default_route
      request('vm-a', op: 'gateway', target: "#{prefix}.1")
      info = request('canary', op: 'info')
      %w[tcp udp].each do |protocol|
        request('vm-a', op: 'blocked', proto: protocol,
                        target: "#{@canary_ip}:#{info.fetch(protocol)}", payload: payload)
      end
      %w[container-a vm-a].each do |source|
        request(source, op: 'blocked', proto: 'tcp', target: '1.1.1.1:443', payload: payload)
        request(source, op: 'blocked-dns', target: '1.1.1.1:53', name: 'example.com')
      end
    end

    def restart_guest
      guest = guests.fetch('vm-b')
      identity = [guest.ip, guest.mac]
      guest.stop
      channel = @channels.fetch('vm-b')
      channel.stop
      replace_channel('vm-b', channel.command)
      guest.start
      raise Failure, 'Guest lease changed' unless identity == [guest.ip, guest.mac]
    end

    def replace_channel(name, command)
      @channels[name] = PacketChannel.new(directory: directory, name: name, command: command).start
    end

    def restart_container
      id = containers.fetch('container-b')
      before = verify_container(id).dig('NetworkSettings', 'Networks', @network)
      @runtime.run('stop', id)
      raise Failure, 'Container did not stop' if verify_container(id).dig('State', 'Running')

      @runtime.run('start', id)
      wait_probe('container-b')
      after = verify_container(id).dig('NetworkSettings', 'Networks', @network)
      return if before.values_at('IPAddress', 'MacAddress') == after.values_at('IPAddress', 'MacAddress')

      raise Failure, 'Container lease changed'
    end
  end
end
