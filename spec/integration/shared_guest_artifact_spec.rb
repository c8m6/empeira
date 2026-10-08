# frozen_string_literal: true

require_relative '../support/shared_network/commands'
require_relative '../support/shared_network/assets'
require_relative '../support/shared_network/guest'
require_relative '../support/shared_network/socket_guest'

RSpec.describe 'Shared network guest artifacts in explicit TCG', :integration do
  it 'boots two diskless guests and exchanges TCP/UDP over one isolated Ethernet stream' do
    unless ENV['EMPEIRA_SHARED_GUEST_CHECK'] == '1'
      skip 'Set EMPEIRA_SHARED_GUEST_CHECK=1 for the TCG artifact diagnostic, not the Podman/KVM proof'
    end

    assets = SharedNetworkProof::Assets.new.prepare
    guests = []
    Dir.mktmpdir('enp-guest-') do |directory|
      %w[vm-a vm-b].each_with_index do |name, index|
        identity = { name: name, ip: "10.203.0.#{10 + index}", mac: "02:ee:00:00:00:0#{index + 1}", tap: nil,
                     token: 'artifact' }
        guest = SharedNetworkProof::SocketGuest.new(commands: SharedNetworkProof::Commands.new, assets: assets,
                                                    directory: directory, identity: identity,
                                                    socket: File.join(directory, 'ethernet.sock'), listen: index.zero?)
        guests << guest
        guest.start
      end
      [[0, 1], [1, 0]].each do |source, target|
        info = guests[target].request(op: 'info')
        %w[tcp udp].each do |proto|
          guests[source].request(op: 'probe', proto: proto, target: "#{guests[target].ip}:#{info.fetch(proto)}",
                                 payload: [SecureRandom.random_bytes(proto == 'tcp' ? 16_384 : 1200)].pack('m0'))
          puts "PASS artifact #{guests[source].name} -> #{guests[target].name} #{proto} (TCG/Unix Ethernet only)"
        end
      end
    ensure
      guests.reverse_each(&:stop)
    end
  end
end
