# frozen_string_literal: true

RSpec.describe Empeira::Server::EnvironmentConfiguration do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
  let(:runtime) { instance_double(Empeira::Runtime::Podman) }
  let(:resource) { { 'id' => 'owned-server' } }
  let(:setting) { '0' }
  let(:operations) { [] }
  subject(:configuration) { described_class.new(runtime: runtime, plan: plan) }

  before do
    allow(runtime).to receive(:service_exec) do |server, arguments|
      expect(server).to eq(resource)
      operations << arguments
      Empeira::Execution::Result.new(stdout: arguments[2] == 'print' ? setting : '', stderr: '',
                                     exit_status: 0, timed_out: false)
    end
  end

  it 'checks the effective native setting without restarting an unchanged server' do
    expect(runtime).not_to receive(:stop_service)
    expect(runtime).not_to receive(:start_service)
    expect(configuration.reconcile(resource)).to be(false)
    expect(operations).to eq([%w[/opt/puppetlabs/bin/puppet config print environment_timeout
                                 --section server --confdir /etc/puppetlabs/puppet]])
  end

  context 'with drift' do
    let(:setting) { 'unlimited' }

    it 'changes only the environment timeout and restarts the same owned server' do
      expect(runtime).to receive(:stop_service).with(resource).ordered
      expect(runtime).to receive(:start_service).with(resource).ordered
      expect(configuration.reconcile(resource)).to be(true)
      expect(operations.last).to eq(%w[/opt/puppetlabs/bin/puppet config set environment_timeout 0
                                       --section server --confdir /etc/puppetlabs/puppet])
    end

    it 'rejects a startup mechanism that overwrites the enforced setting' do
      expect { configuration.verify!(resource) }.to raise_error(Empeira::Error, /not 0 after startup/)
    end
  end

  it 'reports a native configuration failure before stopping the server' do
    result = Empeira::Execution::Result.new(stdout: '', stderr: 'configuration is read-only',
                                            exit_status: 1, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(result)
    expect(runtime).not_to receive(:stop_service)
    expect { configuration.reconcile(resource) }.to raise_error(Empeira::Error, /Exit code: 1.*read-only/m)
  end
end
