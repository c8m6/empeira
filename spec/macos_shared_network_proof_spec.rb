# frozen_string_literal: true

require_relative 'support/shared_network/commands'
require_relative 'support/shared_network/mac_assets'
require_relative 'support/shared_network/mac_guest'
require_relative 'support/shared_network/mac_topology'

RSpec.describe 'macOS shared network proof contracts' do
  describe SharedNetworkProof::MacGuest do
    it 'requires native HVF with exactly one private Ethernet channel and no application forwarding' do
      identity = { name: 'vm-a', ip: '10.204.1.10', mac: '02:ee:00:00:00:01', token: 'owned' }
      guest = described_class.new(commands: instance_double(SharedNetworkProof::Commands),
                                  assets: instance_double(SharedNetworkProof::MacAssets, path: '/cache/file'),
                                  directory: Dir.tmpdir, socket: '/private/owned/ethernet.sock',
                                  identity: identity)
      args = guest.arguments
      expect(args[args.index('-accel') + 1]).to eq('hvf')
      expect(args[args.index('-machine') + 1]).to eq('virt,gic-version=3')
      expect(args[args.index('-netdev') + 1])
        .to eq('stream,id=peer,server=off,addr.type=unix,addr.path=/private/owned/ethernet.sock')
      expect(args.join(' ')).not_to match(/tcg|hostfwd|guestfwd|netdev user/)
    end
  end

  describe SharedNetworkProof::MacAssets do
    it 'keeps architecture caches and pins separate without changing the Linux proof defaults' do
      mac = described_class.new
      linux = SharedNetworkProof::Assets.new
      expect(mac.directory).to eq(File.join(linux.directory, 'aarch64'))
      expect(described_class::DIGESTS.values).to all(match(/\A[0-9a-f]{64}\z/))
      expect(described_class::DIGESTS).not_to eq(SharedNetworkProof::Assets::DIGESTS)
      expect(mac.send(:init_content)).to include('EMPEIRA_PROOF_READY', '/dev/ttyAMA0')
      expect(linux.send(:init_content)).to include('/dev/ttyS0')
    end
  end

  describe SharedNetworkProof::PodmanMachine do
    let(:commands) { instance_double(SharedNetworkProof::Commands) }
    let(:runtime) { described_class.new(commands: commands, machine: 'proof-machine') }

    it 'rejects rootful execution rather than changing the machine settings' do
      allow(commands).to receive(:run).with('podman', '--connection', 'proof-machine', 'info', '--format', 'json')
                                      .and_return(JSON.generate(host: { security: { rootless: false } }))
      expect { runtime.check }.to raise_error(SharedNetworkProof::Failure, /rootless/)
    end

    it 'quotes a binary exec command through the supported SSH entry point without allocating a terminal' do
      command = runtime.namespace_command('/shared path/adapter', 'tap', 'owned', 'bridge')
      expect(command.first(4)).to eq(%w[podman machine ssh proof-machine])
      expect(Shellwords.split(command.last)).to eq(['podman', 'unshare', '--rootless-netns',
                                                    '/shared path/adapter', 'tap', 'owned', 'bridge'])
      expect(command).not_to include('sudo', '--privileged', '-t')
    end
  end

  describe SharedNetworkProof::MacTopology do
    let(:runtime) { instance_double(SharedNetworkProof::DockerDesktop) }
    let(:topology) { described_class.new(runtime: runtime, assets: instance_double(SharedNetworkProof::MacAssets)) }

    after { FileUtils.remove_entry_secure(topology.directory) if File.directory?(topology.directory) }

    it 'records ownership intent before issuing a create that can have an uncertain result' do
      allow(runtime).to receive(:run).with('network', 'ls', '--format', '{{.Name}}').and_return('')
      allow(runtime).to receive(:network_options).and_return([])
      expect(runtime).to receive(:run).with('network', 'create', any_args) do |*args|
        journal = JSON.parse(File.read(File.join(topology.directory, 'ownership.json')))
        expect(journal.fetch('intents').fetch('networks')).to have_key(args.last)
        raise SharedNetworkProof::Failure, 'uncertain create'
      end
      expect { topology.send(:create_network) }.to raise_error(SharedNetworkProof::Failure, /uncertain/)
    end

    it 'refuses cleanup of a same-name resource with a different immutable ID' do
      name = 'proof-container'
      topology.send(:intent, 'containers', name)
      topology.send(:record, 'containers', name, 'original')
      allow(runtime).to receive(:run).with('ps', '-a', '--format', '{{.Names}}').and_return(name)
      allow(runtime).to receive(:run).with('inspect', name).and_return(JSON.generate([
                                                                                       { Id: 'replacement',
                                                                                         Config: { Labels: { SharedNetworkProof::Ownership::LABEL => topology.token } } }
                                                                                     ]))
      expect(runtime).not_to receive(:run).with('rm', any_args)
      expect do
        topology.send(:remove_owned, 'containers', name)
      end.to raise_error(SharedNetworkProof::Failure, /ownership/)
    end

    it 'does not expose host ports or grant forwarding to a normal probe' do
      options = topology.send(:container_options, 'probe', '10.204.1.131', {})
      expect(options).to include('net.ipv4.ip_forward=0', 'net.ipv6.conf.all.disable_ipv6=1', '--read-only')
      expect(options).not_to include('--publish', '--privileged', '--network=host')
    end

    it 'retains network anchors when a packet process cannot be stopped' do
      channel = instance_double(SharedNetworkProof::PacketChannel, stopped?: false)
      allow(channel).to receive(:stop).and_raise(SharedNetworkProof::Failure, 'still running')
      topology.instance_variable_get(:@channels)['vm-a'] = channel
      expect(runtime).not_to receive(:run)
      expect { topology.cleanup }.to raise_error(SharedNetworkProof::Failure, /still running/)
    end

    it 'cleans owned resources after a packet process exited with an error and retains its diagnostic logs' do
      channel = instance_double(SharedNetworkProof::PacketChannel, stopped?: true)
      allow(channel).to receive(:stop).and_raise(SharedNetworkProof::Failure, 'transport failed')
      topology.instance_variable_get(:@channels)['vm-a'] = channel
      topology.send(:intent, 'containers', 'owned-container')
      expect(topology).to receive(:remove_owned).with('containers', 'owned-container')
      expect { topology.cleanup }.to raise_error(SharedNetworkProof::Failure, /resources removed, logs retained/)
    end
  end
end
