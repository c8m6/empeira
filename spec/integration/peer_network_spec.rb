# frozen_string_literal: true

require_relative '../support/peer_network_fixture'

RSpec.describe 'Production shared peer network', :integration do
  include ProductionPeerFixture

  before do
    skip 'Set EMPEIRA_PEER_NETWORK=1 and EMPEIRA_VM_RUNTIME=podman or docker on an accelerated host' unless
      ENV['EMPEIRA_PEER_NETWORK'] == '1'

    prepare_peer_project
    peer_app.infrastructure.up
    peer_app.run_node(hostname: 'container-peer', provider: 'container')
    %w[vm-one vm-two].each { |name| peer_app.run_node(hostname: name, provider: 'vm') }
    prepare_peer_endpoints
  end

  after do
    next unless ENV['EMPEIRA_PEER_NETWORK'] == '1' && @peer_app

    @peer_canary&.stop
    peer_app.infrastructure.destroy
    expect(Empeira::Infrastructure::Store.new(context: peer_app.context).load).to be_nil
    puts 'PASS production cleanup: guests, adapters, services, network and inventory removed'
  end

  it 'runs catalogs and direct TCP/UDP/DNS/HTTP peers, isolates guests and preserves leases across restart' do
    peer_matrix
    peer_dns_and_isolation
    before = peer_state.fetch('nodes')
    %w[container-peer vm-two].each do |name|
      peer_app.nodes.stop(name: name)
      files = Empeira::ControlPlane::Files.new(context: peer_app.context)
      expect(File.read(files.path('hosts'))).to include(name)
      peer_app.nodes.start(name: name)
    end
    expect(peer_state.dig('nodes', 'vm-two', 'peer')).to eq(before.dig('vm-two', 'peer'))
    expect(peer_state.dig('nodes', 'container-peer', 'id')).to eq(before.dig('container-peer', 'id'))
    expect(peer_state.dig('nodes', 'container-peer', 'definition')).to eq(before.dig('container-peer', 'definition'))
    verify_container_lease
    prepare_peer_endpoints
    peer_matrix
    peer_app.nodes.destroy(name: 'vm-two')
    expect(peer_state.fetch('nodes')).not_to have_key('vm-two')
    files = Empeira::ControlPlane::Files.new(context: peer_app.context)
    expect(File.read(files.path('hosts'))).not_to include('vm-two')
    expect(peer_state).not_to have_key('bootstrap_proxy')
  end
end
