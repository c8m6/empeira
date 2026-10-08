# frozen_string_literal: true

require 'tmpdir'
require_relative 'checks'
require_relative 'dns'
require_relative 'packet_channel'
require_relative 'mac_runtime'
require_relative 'mac_resources'
require_relative 'mac_checks'
require_relative 'mac_cleanup'

module SharedNetworkProof
  # Opt-in proof only; production orchestration and the finalized Linux proof are unchanged.
  class MacTopology
    include Checks
    include MacResources
    include MacChecks
    include MacCleanup

    attr_reader :assets, :token, :bridge, :prefix, :containers, :guests, :addresses, :directory

    def initialize(runtime:, assets:, commands: Commands.new)
      @runtime = runtime
      @assets = assets
      @commands = commands
      @token = SecureRandom.hex(6)
      @directory = Dir.mktmpdir('emp-')
      @bridge = "ep#{token[0, 10]}"
      @network = "empeira-macos-proof-#{token}"
      @prefix = "10.204.#{token[0, 2].to_i(16)}"
      @containers = {}
      @guests = {}
      @channels = {}
      @intents = { 'networks' => {}, 'containers' => {} }
      configure_addresses
      journal
    end

    def start
      @runtime.check
      assets.prepare
      build_image
      @runtime.run('pull', DNS::IMAGE, timeout: 120)
      create_network
      start_dns
      %w[container-a container-b service browser].each { |name| start_probe(name, addresses.fetch(name)) }
      %w[vm-a vm-b vm-c].each_with_index { |name, index| start_guest(name, index) }
      start_canary
      self
    end

    def request(name, **operation)
      return guests.fetch(name).request(**operation) if guests.key?(name)

      output = @runtime.run('exec', containers.fetch(name), '/probe', 'request', JSON.generate(operation), timeout: 8)
      reply = JSON.parse(output)
      raise Failure, "#{name}: #{reply['error']}" unless reply['ok']

      reply
    end

    def start_probe(name, ip, capabilities: [], devices: [])
      security = ['--cap-drop=all', '--security-opt=no-new-privileges']
      security += capabilities.flat_map { |capability| ['--cap-add', capability] }
      security += devices.flat_map { |device| ['--device', device] }
      create_container(name, ip, security, assets.image, ['daemon', name])
      wait_probe(name)
    end

    def guest_mac(index)
      "02:ee:#{token.scan(/../).first(3).join(':')}:0#{index + 1}"
    end

    private

    def configure_addresses
      @addresses = %w[dns container-a container-b service browser].each_with_index.to_h do |name, index|
        [name, "#{prefix}.#{130 + index}"]
      end.merge(%w[vm-a vm-b vm-c].each_with_index.to_h { |name, index| [name, "#{prefix}.#{10 + index}"] })
    end

    def build_image
      context = File.join(directory, 'build')
      FileUtils.mkdir_p(context)
      %w[probe adapter Containerfile].each { |name| FileUtils.cp(assets.path(name), File.join(context, name)) }
      @runtime.run('build', '--network=none', '-f', File.join(context, 'Containerfile'),
                   '-t', assets.image, context, timeout: 120)
    end

    def start_dns
      file = File.join(directory, 'Corefile')
      hosts = addresses.map { |name, ip| "#{ip} #{name}.empeira.internal #{name}" }.join("\n")
      File.write(file, ".:53 {\n hosts {\n#{hosts}\n ttl 1\n }\n errors\n}\n")
      create_container('dns', addresses.fetch('dns'), ['--volume', "#{file}:/Corefile:ro"],
                       DNS::IMAGE, ['-conf', '/Corefile'])
    end

    def start_guest(name, index)
      command = @runtime.peer_command(self, name, index)
      channel = PacketChannel.new(directory: directory, name: name, command: command)
      @channels[name] = channel.start
      guest = MacGuest.new(commands: @commands, assets: assets, directory: directory,
                           identity: guest_identity(name, index), socket: channel.path)
      guests[name] = guest
      puts "Starting #{name} with native arm64/HVF and private Ethernet channel"
      guest.start
    end

    def guest_identity(name, index)
      { name: name, ip: addresses.fetch(name), mac: guest_mac(index), tap: nil, token: token }
    end

    def wait_probe(name)
      Timeout.timeout(15) do
        loop do
          return if request(name, op: 'info')['tcp']
        rescue Failure
          sleep 0.2
        end
      end
    end
  end
end
