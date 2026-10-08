# frozen_string_literal: true

require_relative 'support/shared_network/commands'
require_relative 'support/shared_network/assets'
require_relative 'support/shared_network/guest'
require_relative 'support/shared_network/topology'

RSpec.describe 'Shared network proof contracts' do
  describe SharedNetworkProof::Commands do
    it 'reports bounded stdout, stderr, exit status and timeout without arguments or environment secrets' do
      runner = instance_double(Empeira::Execution::Runner)
      result = Empeira::Execution::Result.new(stdout: "probe error secret-value #{'x' * 3000}",
                                              stderr: 'runtime error', exit_status: 1, timed_out: true)
      allow(runner).to receive(:run).and_return(result)
      expect do
        described_class.new(runner: runner).run('podman', 'secret-argument',
                                                environment: { 'TOKEN' => 'secret-value' })
      end.to raise_error(SharedNetworkProof::Failure) { |error|
        expect(error.message).to include('podman failed', 'exit=1', 'timeout=true',
                                         'stdout="probe error [REDACTED]', 'stderr="runtime error"', '[truncated]')
        expect(error.message).not_to include('secret-value', 'secret-argument')
        expect(error.message.bytesize).to be < 2200
      }
    end
  end

  describe SharedNetworkProof::Archive do
    it 'encodes executable binary files with valid newc lengths, alignment and trailer' do
      archive = described_class.overlay(init: '#!/bin/sh', probe: "\x00\xffbinary".b)
      entries = {}
      cursor = 0
      loop do
        expect(archive[cursor, 6]).to eq('070701')
        fields = archive[cursor + 6, 104].scan(/.{8}/).map { |hex| hex.to_i(16) }
        name = archive[cursor + 110, fields[11] - 1]
        start = (cursor + 110 + fields[11] + 3) & ~3
        entries[name] = [fields[1], archive[start, fields[6]]]
        cursor = (start + fields[6] + 3) & ~3
        break if name == 'TRAILER!!!'
      end
      expect(entries).to eq('init' => [0o100755, '#!/bin/sh'],
                            'probe' => [0o100755, "\x00\xffbinary".b], 'TRAILER!!!' => [0, ''])
      expect(archive.bytesize % 512).to eq(0)
    end
  end

  describe SharedNetworkProof::Routes do
    it 'rejects both larger and smaller overlapping routes before network creation' do
      %w[10.203.0.0/16 10.203.1.128/25 10.203.1.10/32].each do |route|
        expect { described_class.reject_overlap!([{ 'dst' => route }], '10.203.1.0/24') }
          .to raise_error(SharedNetworkProof::Failure, /overlaps/)
      end
    end

    it 'allows adjacent subnets and an existing default route' do
      expect do
        described_class.reject_overlap!([{ 'dst' => 'default' }, { 'dst' => '10.203.2.0/24' }], '10.203.1.0/24')
      end.not_to raise_error
    end
  end

  describe SharedNetworkProof::Ownership do
    it 'requires both immutable identity and the private proof token' do
      resource = { 'Id' => 'id-1', 'Config' => { 'Labels' => { described_class::LABEL => 'token' } } }
      expect { described_class.verify!(resource, id: 'id-1', token: 'token') }.not_to raise_error
      expect { described_class.verify!(resource, id: 'same-name-different-id', token: 'token') }
        .to raise_error(SharedNetworkProof::Failure)
      expect { described_class.verify!(resource, id: 'id-1', token: 'foreign') }
        .to raise_error(SharedNetworkProof::Failure)
    end
  end

  describe SharedNetworkProof::Prerequisites do
    it 'rejects missing host capabilities without running or creating runtime resources' do
      commands = instance_double(SharedNetworkProof::Commands, available?: false)
      expect(commands).not_to receive(:podman)
      expect { described_class.check!(commands: commands) }
        .to raise_error(SharedNetworkProof::Failure, /blocked:.*host executable podman/)
    end

    it 'rejects rootful Podman rather than silently falling back' do
      commands = instance_double(SharedNetworkProof::Commands)
      allow(described_class).to receive(:missing_capabilities).and_return([])
      allow(commands).to receive(:podman).with('info', '--format', 'json')
                                         .and_return(JSON.generate(host: { security: { rootless: false } }))
      expect { described_class.check!(commands: commands) }
        .to raise_error(SharedNetworkProof::Failure, /no rootful fallback/)
    end
  end

  describe SharedNetworkProof::Guest do
    let(:guest) do
      described_class.new(commands: instance_double(SharedNetworkProof::Commands),
                          assets: instance_double(SharedNetworkProof::Assets, path: '/cache/artifact'),
                          directory: Dir.tmpdir,
                          identity: { name: 'vm-a', ip: '10.203.1.10', mac: '02:ee:01:02:00:01',
                                      tap: 'owned-tap', token: 'unique' })
    end

    it 'requires KVM and one TAP with no user networking or application forwarding' do
      arguments = guest.arguments
      expect(arguments[arguments.index('-accel') + 1]).to eq('kvm')
      expect(arguments[arguments.index('-netdev') + 1]).to eq('tap,id=peer,ifname=owned-tap,script=no,downscript=no')
      expect(arguments.join(' ')).not_to match(/hostfwd|guestfwd|restrict=|tcg/)
    end

    it 'ignores boot logs and stale requests but fails on the matching negative reply' do
      stale = JSON.generate(id: 'old', ok: true)
      failure = JSON.generate(id: 'current', ok: false, error: 'bad payload')
      serial = StringIO.new("Linux boot\n#{stale}\n#{failure}\n")
      guest.instance_variable_set(:@serial, serial)
      expect { guest.send(:read_response, 'current') }.to raise_error(SharedNetworkProof::Failure, /bad payload/)
    end

    it 'fails if the serial channel closes instead of waiting forever' do
      guest.instance_variable_set(:@serial, StringIO.new(''))
      expect { guest.send(:read_response, 'current') }.to raise_error(SharedNetworkProof::Failure, /console closed/)
    end
  end

  describe SharedNetworkProof::Topology do
    let(:commands) { instance_double(SharedNetworkProof::Commands) }
    let(:topology) { described_class.new(commands: commands, assets: instance_double(SharedNetworkProof::Assets)) }

    after { FileUtils.remove_entry_secure(topology.directory) if File.directory?(topology.directory) }

    def container_observation(topology, running: true, ip: topology.addresses.fetch('container-b'))
      { 'Id' => 'owned', 'Config' => { 'Labels' => {
        SharedNetworkProof::Ownership::LABEL => topology.instance_variable_get(:@token)
      } }, 'State' => { 'Running' => running }, 'NetworkSettings' => { 'Networks' => {
        topology.instance_variable_get(:@network) => { 'IPAddress' => ip, 'MacAddress' => '02:00:00:00:00:01' }
      } } }
    end

    it 'keeps probe security restrictions separate from the official CoreDNS fixture' do
      %w[container-b dns].each do |name|
        expect(commands).to receive(:podman).with('create', any_args) do |*arguments|
          restrictions = %w[--cap-drop=all --security-opt=no-new-privileges]
          expect(arguments & restrictions).to eq(name == 'dns' ? [] : restrictions)
          'owned'
        end
        allow(commands).to receive(:podman).with('inspect', 'owned')
                                           .and_return(JSON.generate([container_observation(topology)]))
        expect(commands).to receive(:podman).with('start', 'owned')
        topology.send(:run_container, name, [], 'fixture', [])
      end
    end

    it 'reports CoreDNS state and logs automatically on startup failure' do
      topology.containers['dns'] = 'owned'
      allow(topology).to receive(:run_container).and_raise(SharedNetworkProof::Failure, 'start failed')
      allow(commands).to receive(:podman).with('inspect', 'owned')
                                         .and_return(JSON.generate([{ 'State' => { 'ExitCode' => 126 } }]))
      allow(commands).to receive(:podman).with('logs', '--tail', '30', 'owned').and_return('permission denied')
      allow(commands).to receive(:diagnostic, &:inspect)
      expect { topology.send(:start_dns) }.to raise_error(SharedNetworkProof::Failure) { |error|
        expect(error.message).to include('CoreDNS startup failed', '126', 'permission denied')
      }
    end

    it 'uses port 53 and stays quiet when CoreDNS starts and answers readiness queries' do
      expect(topology).to receive(:run_container).with('dns', anything, SharedNetworkProof::DNS::IMAGE,
                                                       ['-conf', '/Corefile'])
      expect(topology).to receive(:request).with('container-a', op: 'dns',
                                                                target: "#{topology.addresses.fetch('dns')}:53",
                                                                name: 'vm-a.empeira.internal',
                                                                want: topology.addresses.fetch('vm-a'))
      expect do
        topology.send(:start_dns)
        topology.send(:wait_dns)
      end.not_to output.to_stdout
      expect(File.read(File.join(topology.directory, 'Corefile'))).to start_with('.:53')
    end

    it 'stops and starts the same owned container and verifies its observed address' do
      topology.containers['container-b'] = 'owned'
      observations = [container_observation(topology), container_observation(topology, running: false),
                      container_observation(topology)]
      allow(commands).to receive(:podman).with('inspect', 'owned')
                                         .and_return(*observations.map { |item| JSON.generate([item]) })
      expect(commands).to receive(:podman).with('stop', 'owned').ordered
      expect(commands).to receive(:podman).with('start', 'owned').ordered
      expect(topology).to receive(:wait_container).with('container-b').ordered
      topology.send(:restart_container)
      expect(topology.containers.fetch('container-b')).to eq('owned')
    end

    it 'rejects an unexpected runtime address for an existing lease' do
      topology.containers['container-b'] = 'owned'
      allow(commands).to receive(:podman).with('inspect', 'owned')
                                         .and_return(JSON.generate([container_observation(topology, ip: '10.0.0.99')]))
      expect { topology.send(:verify_container_lease, 'container-b', 'owned') }
        .to raise_error(SharedNetworkProof::Failure, /active node lease/)
    end

    it 'allocates a fresh container MAC per creation, even for the same fixture name and IP' do
      assets = instance_double(SharedNetworkProof::Assets, image: 'fixture')
      topology.instance_variable_set(:@assets, assets)
      allow(SecureRandom).to receive(:hex).with(5).and_return('0000000001', '0000000002')
      options = []
      allow(topology).to receive(:run_container) { |_, network, _, _| options << network }
      allow(topology).to receive(:wait_container)
      2.times { topology.send(:start_container, 'container-b') }
      macs = options.map { |network| network[network.index('--mac-address') + 1] }
      expect(macs).to all(match(/\A02(?::[0-9a-f]{2}){5}\z/))
      expect(macs.uniq.size).to eq(2)
    end

    it 'rejects a MAC change after restart even when the container ID and IP are retained' do
      topology.containers['container-b'] = 'owned'
      restarted = container_observation(topology)
      restarted.fetch('NetworkSettings').fetch('Networks').each_value do |network|
        network['MacAddress'] = '02:00:00:00:00:02'
      end
      observations = [container_observation(topology), container_observation(topology, running: false), restarted]
      allow(commands).to receive(:podman).with('inspect', 'owned')
                                         .and_return(*observations.map { |item| JSON.generate([item]) })
      allow(commands).to receive(:podman).with('stop', 'owned')
      allow(commands).to receive(:podman).with('start', 'owned')
      allow(topology).to receive(:wait_container)
      expect { topology.send(:restart_container) }
        .to raise_error(SharedNetworkProof::Failure, /active network identity/)
    end

    it 'verifies runtime removal before releasing the fixture address without creating a replacement' do
      topology.containers['container-b'] = 'owned'
      allow(commands).to receive(:podman).with('inspect', 'owned')
                                         .and_return(JSON.generate([container_observation(topology)]))
      expect(commands).to receive(:podman).with('rm', '--force', 'owned').ordered
      expect(commands).to receive(:podman).with('ps', '--all', '--quiet', '--no-trunc').ordered.and_return('other')
      expect { topology.send(:destroy_container) }.to output(%r{PASS container destroy/release}).to_stdout
      expect(topology.containers).not_to have_key('container-b')
      expect(topology.addresses).not_to have_key('container-b')
    end

    it 'reserves unique guest addresses outside the runtime allocation range' do
      ips = topology.addresses.values.map { |ip| IPAddr.new(ip) }
      expect(ips.uniq).to eq(ips)
      expect(topology.addresses.values_at('vm-a', 'vm-b', 'vm-c').map { |ip| ip.split('.').last.to_i })
        .to all(be < 128)
    end

    it 'keeps namespace anchors and TAPs when guest shutdown cannot be verified' do
      guest = instance_double(SharedNetworkProof::Guest)
      allow(guest).to receive(:stop).and_raise(SharedNetworkProof::Failure, 'ownership mismatch')
      topology.guests['vm-a'] = guest
      expect(commands).not_to receive(:podman)
      expect(commands).not_to receive(:namespace)
      expect { topology.cleanup }.to raise_error(SharedNetworkProof::Failure, /Guest shutdown uncertain/)
      expect(File.directory?(topology.directory)).to be(true)
    end

    it 'removes guests before TAPs, containers and networks' do
      order = []
      guest = instance_double(SharedNetworkProof::Guest)
      allow(guest).to receive(:stop) { order << :guest }
      topology.guests['vm-a'] = guest
      topology.containers['dns'] = 'owned'
      topology.instance_variable_set(:@taps, ['tap'])
      topology.instance_variable_set(:@networks, [{ id: 'network' }])
      allow(topology).to receive(:remove_tap) { order << :tap }
      allow(topology).to receive(:remove_container) { order << :container }
      allow(topology).to receive(:remove_network) { order << :network }
      topology.cleanup
      expect(order).to eq(%i[guest tap container network])
      expect(File.exist?(topology.directory)).to be(false)
    end
  end
end
