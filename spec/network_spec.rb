# frozen_string_literal: true

RSpec.describe Empeira::Network::Policy do
  it 'requires isolation' do
    expect { described_class.new.require_support!(isolated: false, controlled_egress: true) }
      .to raise_error(Empeira::Network::UnsupportedPolicy, /Isolated/)
  end

  it 'accepts isolated networking' do
    expect { described_class.new.require_support!(isolated: true, controlled_egress: false) }.not_to raise_error
    expect { described_class.new.require_support!(isolated: 'true', controlled_egress: false) }
      .to raise_error(Empeira::Network::UnsupportedPolicy)
  end

  it 'fails before provisioning when the adapter cannot guarantee isolation' do
    application = Empeira::Application.new(project_path: @directory)
    network = Empeira::Network::Interface.new(context: application.context, runner: application.runner)
    expect(network).not_to receive(:create)
    expect { network.provision(policy: described_class.new) }.to raise_error(Empeira::Network::UnsupportedPolicy)
  end
end
