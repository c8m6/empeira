# frozen_string_literal: true

require_relative '../support/shared_network/commands'
require_relative '../support/shared_network/mac_assets'
require_relative '../support/shared_network/mac_guest'
require_relative '../support/shared_network/mac_topology'

RSpec.describe 'Experimental macOS shared peer network', :integration do
  %w[podman docker].each do |name|
    it "connects native HVF guests to #{name} peers with arbitrary TCP/UDP and CoreDNS" do
      skip "Set EMPEIRA_MACOS_NETWORK=#{name} for the real macOS proof" unless ENV['EMPEIRA_MACOS_NETWORK'] == name
      unless RUBY_PLATFORM.match?(/arm64-darwin/)
        raise SharedNetworkProof::Failure,
              'Requires native Apple Silicon macOS'
      end

      commands = SharedNetworkProof::Commands.new
      runtime = if name == 'podman'
                  SharedNetworkProof::PodmanMachine.new(commands: commands, machine: ENV.fetch('EMPEIRA_PROOF_MACHINE'))
                else
                  SharedNetworkProof::DockerDesktop.new(commands: commands)
                end
      topology = SharedNetworkProof::MacTopology.new(runtime: runtime, commands: commands,
                                                     assets: SharedNetworkProof::MacAssets.new(commands: commands))
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
end
