# frozen_string_literal: true

module SharedNetworkProof
  module Lifecycle
    def lifecycle
      restart_guest
      restart_container
      verify_forwarding
      matrix
      dns_and_browser
      puts 'PASS VM and container stop/start: same node instances and leases, TCP/UDP restored'
      destroy_container
    end

    private

    def restart_guest
      guest = guests.fetch('vm-b')
      identity = [guest.ip, guest.mac, guest.tap]
      guest.stop
      port = request('vm-c', op: 'info').fetch('udp')
      request('vm-a', op: 'probe', proto: 'udp', target: "#{addresses.fetch('vm-c')}:#{port}", payload: payload)
      guest.start
      verify_guest_lease(guest, identity)
    end

    def verify_guest_lease(guest, identity)
      return if guests.fetch('vm-b').equal?(guest) && identity == [guest.ip, guest.mac, guest.tap] &&
                guest.ip == addresses.fetch('vm-b')

      raise Failure, 'VM stop/start changed the active node lease'
    end

    def restart_container
      name = 'container-b'
      id = containers.fetch(name)
      mac = verify_container_lease(name, id)
      @commands.podman('stop', id)
      raise Failure, 'Container did not stop' if inspect_container(name, id).dig('State', 'Running')

      @commands.podman('start', id)
      wait_container(name)
      return if verify_container_lease(name, id) == mac

      raise Failure, 'Container stop/start changed the active network identity'
    end

    def inspect_container(name, id)
      raise Failure, 'Container instance changed' unless containers.fetch(name) == id

      observed = JSON.parse(@commands.podman('inspect', id)).first
      Ownership.verify!(observed, id: id, token: @token)
      observed
    end

    def verify_container_lease(name, id)
      observed = inspect_container(name, id)
      network = observed.dig('NetworkSettings', 'Networks', @network)
      return network.fetch('MacAddress') if observed.dig('State', 'Running') &&
                                            network&.fetch('IPAddress') == addresses.fetch(name)

      raise Failure, 'Container stop/start changed the active node lease or running state'
    end

    def destroy_container
      name = 'container-b'
      id = containers.fetch(name)
      remove_container(name)
      remaining = @commands.podman('ps', '--all', '--quiet', '--no-trunc').split
      raise Failure, 'Destroyed container still exists in the runtime' if remaining.include?(id)

      # Runtime removal releases the endpoint; relinquish the fixture's lease as well.
      # No replacement or immediate IP/MAC reuse is required, avoiding stale ARP assumptions.
      addresses.delete(name)
      puts 'PASS container destroy/release: owned runtime resource removed and fixture lease released'
    end
  end
end
