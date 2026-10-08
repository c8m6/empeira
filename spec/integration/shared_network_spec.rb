# frozen_string_literal: true

require_relative '../support/shared_network/commands'
require_relative '../support/shared_network/assets'
require_relative '../support/shared_network/guest'
require_relative '../support/shared_network/topology'

RSpec.describe 'Experimental shared Podman TAP network', :integration do
  it 'connects containers and three KVM guests over TCP/UDP, verifies isolation, and removes owned resources' do
    unless ENV['EMPEIRA_SHARED_NETWORK'] == '1'
      skip 'Set EMPEIRA_SHARED_NETWORK=1 on Linux/WSL2 with rootless Podman, TUN and KVM'
    end

    SharedNetworkProof::Prerequisites.check!
    topology = SharedNetworkProof::Topology.new
    begin
      topology.start
      topology.matrix
      topology.dns_and_browser
      topology.isolation
      topology.lifecycle
    ensure
      topology.cleanup
    end
  end
end
