# frozen_string_literal: true

require 'tmpdir'

require_relative 'checks'
require_relative 'resources'
require_relative 'dns'
require_relative 'lifecycle'

module SharedNetworkProof
  # Opt-in fixture only. No production controller, provider image, or application port publication.
  class Topology
    include Checks
    include Resources
    include DNS
    include Lifecycle

    attr_reader :guests, :containers, :addresses, :directory

    def initialize(commands: Commands.new, assets: Assets.new)
      @commands = commands
      @assets = assets
      @token = SecureRandom.hex(6)
      @directory = Dir.mktmpdir('enp-')
      @bridge = "ep#{@token[0, 10]}"
      @network = "empeira-proof-#{@token}"
      @networks = []
      @containers = {}
      @taps = []
      @guests = {}
      configure_addresses
    end

    def start
      @assets.prepare
      @commands.podman('build', '--network=none', '-t', @assets.image, @assets.directory, timeout: 120)
      @commands.podman('pull', DNS::IMAGE, timeout: 120)
      create_network(@network, "#{@prefix}.0/24", bridge: @bridge, range: "#{@prefix}.128/25")
      start_dns
      @commands.namespace('test', '-r', '/dev/kvm')
      @commands.namespace('test', '-w', '/dev/kvm')
      %w[container-a container-b service browser].each { |name| start_container(name) }
      wait_dns
      start_canary
      verify_forwarding
      %w[vm-a vm-b vm-c].each_with_index { |name, index| start_guest(name, index) }
      self
    end

    def request(name, **operation)
      return guests.fetch(name).request(**operation) if guests.key?(name)

      output = @commands.podman('exec', containers.fetch(name), '/probe', 'request', JSON.generate(operation),
                                timeout: 8)
      reply = JSON.parse(output)
      raise Failure, "#{name}: #{reply['error']}" unless reply['ok']

      reply
    end

    def cleanup
      errors = []
      stop_guests(errors)
      remove_taps(errors)
      containers.keys.reverse_each { |name| attempt(errors) { remove_container(name) } }
      @networks.reverse_each { |entry| attempt(errors) { remove_network(entry) } }
      finish_cleanup(errors)
    end

    private

    def stop_guests(errors)
      guests.each_value { |guest| attempt(errors) { guest.stop } }
      return if errors.empty?

      raise Failure, "Guest shutdown uncertain; resources retained in #{directory}: #{errors.join('; ')}"
    end

    def remove_taps(errors)
      @taps.reverse_each { |tap| attempt(errors) { remove_tap(tap) } }
      return if errors.empty?

      raise Failure, "TAP cleanup uncertain; namespace anchors retained: #{errors.join('; ')}"
    end

    def configure_addresses
      # Deterministic fixture leases belong to node instances and survive stop/start.
      # Destroy releases a lease; a later node has no entitlement to the same IP or MAC.
      octet = @token[0, 2].to_i(16)
      @prefix = "10.203.#{octet}"
      @addresses = { 'dns' => "#{@prefix}.130", 'container-a' => "#{@prefix}.131",
                     'container-b' => "#{@prefix}.132", 'service' => "#{@prefix}.133", 'browser' => "#{@prefix}.134",
                     'vm-a' => "#{@prefix}.10", 'vm-b' => "#{@prefix}.11", 'vm-c' => "#{@prefix}.12" }
      @outside = "198.18.#{octet}.2"
      @lan = "192.168.#{octet}.2"
    end

    def payload
      ["empeira-proof-#{@token}\0\xff".b].pack('m0')
    end

    def start_guest(name, index)
      tap = "et#{@token[0, 9]}#{index}"
      @commands.namespace('ip', 'tuntap', 'add', 'dev', tap, 'mode', 'tap')
      @taps << tap
      @commands.namespace('ip', 'link', 'set', 'dev', tap, 'alias', "#{@token}:#{tap}")
      @commands.namespace('ip', 'link', 'set', 'dev', tap, 'master', @bridge)
      @commands.namespace('ip', 'link', 'set', 'dev', tap, 'up')
      identity = { name: name, ip: addresses.fetch(name), mac: mac(index),
                   tap: tap, token: @token }
      guest = Guest.new(commands: @commands, assets: @assets, directory: directory, identity: identity)
      guests[name] = guest
      guest.start
    end

    def mac(index)
      "02:ee:#{@token[0, 2]}:#{@token[2, 2]}:00:#{format('%02x', index + 1)}"
    end

    def verify_forwarding
      value = @commands.namespace('cat', "/proc/sys/net/ipv4/conf/#{@bridge}/forwarding").strip
      raise Failure, 'Internal bridge forwarding is enabled; refusing topology' unless value == '0'
    end

    def force_default_routes
      observed = JSON.parse(@commands.podman('inspect', containers.fetch('container-a'))).first
      pid = observed.dig('State', 'Pid').to_s
      @commands.namespace('nsenter', "--net=/proc/#{pid}/ns/net", 'ip', 'route', 'replace', 'default', 'via',
                          "#{@prefix}.1")
      request('vm-a', op: 'gateway', target: "#{@prefix}.1")
    end
  end
end
