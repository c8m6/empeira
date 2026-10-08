# frozen_string_literal: true

module SharedNetworkProof
  module Checks
    def matrix
      pairs = [%w[container-a container-b], %w[container-a vm-a], %w[vm-a container-a],
               %w[vm-a vm-b], %w[vm-b vm-a], %w[vm-c vm-a], %w[vm-a vm-c], %w[service vm-b]]
      pairs.each do |source, destination|
        info = request(destination, op: 'info')
        %w[tcp udp].each do |protocol|
          payload = [SecureRandom.random_bytes(protocol == 'tcp' ? 16_384 : 1200)].pack('m0')
          request(source, op: 'probe', proto: protocol,
                          target: "#{addresses.fetch(destination)}:#{info.fetch(protocol)}", payload: payload)
          puts "PASS #{source} -> #{destination} #{protocol.upcase} payload"
        end
      end
    end

    def dns_and_browser
      %w[container-a vm-a vm-b].each do |source|
        %w[container-a container-b vm-a vm-b vm-c].each do |destination|
          request(source, op: 'dns', target: "#{addresses.fetch('dns')}:53",
                          name: "#{destination}.empeira.internal", want: addresses.fetch(destination))
        end
        puts "PASS #{source} CoreDNS peer addresses"
      end
      info = request('vm-a', op: 'info')
      request('browser', op: 'http', target: "#{addresses.fetch('vm-a')}:#{info.fetch('http')}", want: 'vm-a')
      puts 'PASS browser -> vm-a HTTP'
    end

    def isolation
      probe_canaries('canary', 'probe')
      force_default_routes
      verify_forwarding
      %w[container-a vm-a].each do |source|
        probe_canaries(source, 'blocked')
        request(source, op: 'blocked', proto: 'tcp', target: '1.1.1.1:443', payload: payload)
        request(source, op: 'blocked-dns', target: '1.1.1.1:53', name: 'example.com')
        puts "PASS #{source} off-network TCP/UDP, private canary, public TCP/DNS blocked with forced default route"
      end
      matrix
      dns_and_browser
    end

    private

    def probe_canaries(source, operation)
      info = request('canary', op: 'info')
      [@outside, @lan].each do |ip|
        %w[tcp udp].each do |protocol|
          request(source, op: operation, proto: protocol, target: "#{ip}:#{info.fetch(protocol)}", payload: payload)
        end
      end
    end
  end
end
