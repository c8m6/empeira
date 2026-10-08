# frozen_string_literal: true

require_relative '../resources/gateway/configure'
require_relative '../resources/gateway/bridge'

RSpec.describe 'Workspace gateway attachment' do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:definition) do
    Empeira::Network::Definition.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
  end
  let(:resource) do
    Empeira::Network::Resource.new(id: 'a' * 64, name: definition.backend_name, labels: definition.labels,
                                   isolated: true, attachment_count: 1)
  end
  let(:runtime) { Empeira::Runtime::Docker.new(context: app.context, runner: runner) }

  before do
    definition.allocation = '10.210.40.0/24'
    allow(runtime).to receive(:inspect_network).and_return(resource)
    allow(runtime).to receive(:inspect_service).and_return(nil)
    allow(runtime).to receive(:network_details).and_return(
      'Options' => { 'com.docker.network.bridge.name' => "ep#{app.context.workspace.id[0, 10]}" },
      'IPAM' => { 'Config' => [{ 'Subnet' => definition.allocation }] }
    )
  end

  def attach(action = 'apply')
    runtime.reconcile_workspace_bridge(definition: definition, expected_id: resource.id,
                                       image: 'localhost/empeira-gateway:fixture', action: action)
  end

  it 'bounds the Docker helper to owned attachment rules without host files or privileged containers' do
    expect(runner).to receive(:run) do |engine, arguments:, timeout:|
      expect(engine).to eq('docker')
      expect(timeout).to eq(30)
      expect(arguments).to include('--read-only', 'NET_ADMIN', 'NET_RAW', '--network', 'host',
                                   '/usr/local/libexec/empeira-bridge')
      expect(arguments).not_to include('--privileged', '--volume', '--mount', '--pid')
      expect(arguments.last(4)).to eq(['apply', "ep#{app.context.workspace.id[0, 10]}", '10.210.40.0/24', resource.id])
      Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    end
    attach
  end

  it 'refuses foreign networks, stale IDs and wrong bridge/subnet bindings before any command' do
    expect(runner).not_to receive(:run)
    allow(runtime).to receive(:network_details).and_return('Options' => {}, 'IPAM' => { 'Config' => [] })
    expect { attach }.to raise_error(Empeira::Providers::OwnershipError)
    expect do
      runtime.reconcile_workspace_bridge(definition: definition, expected_id: 'foreign', image: 'fixture',
                                         action: 'remove')
    end.to raise_error(Empeira::Providers::OwnershipError)
  end

  it 'does not invoke a rootful or host helper for Podman' do
    podman = Empeira::Runtime::Podman.new(context: app.context, runner: runner)
    expect(runner).not_to receive(:run)
    podman.reconcile_workspace_bridge(definition: definition, expected_id: nil, image: 'fixture', action: 'apply')
  end

  it 'configures a route in only the owned container namespace for both runtimes' do
    %w[docker podman].each do |engine|
      adapter = Empeira::Runtime.registry.build(engine, context: app.context, runner: runner)
      allow(adapter).to receive(:inspect_service).and_return(nil)
      owned = { 'id' => 'node-id', 'labels' => definition.labels }
      expect(runner).to receive(:run) do |binary, arguments:, **|
        expect(binary).to eq(engine)
        expect(arguments).to include('container:node-id', '--cap-drop', 'ALL', 'NET_ADMIN')
        expect(arguments).not_to include('host', 'NET_RAW', '--privileged')
        expect(arguments.last(3)).to eq(['fixture', 'route', '10.210.40.2'])
        Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      end
      adapter.configure_workspace_route(owned, gateway: '10.210.40.2', image: 'fixture')
    end
  end

  it 'rejects a foreign container before changing its routes' do
    expect(runner).not_to receive(:run)
    expect { runtime.configure_workspace_route({ 'labels' => {} }, gateway: '10.210.40.2', image: 'fixture') }
      .to raise_error(Empeira::Providers::OwnershipError)
  end
end

RSpec.describe EmpeiraBridge do
  it 'generates only same-bridge rules with full network ownership comments' do
    rules = described_class.rules('ep1234567890', '10.210.40.0/24', 'a' * 64)
    expect(rules.size).to eq(2)
    expect(rules.last).to eq(['filter', 'FORWARD', ['-i', 'ep1234567890', '-o', 'ep1234567890',
                                                    '-m', 'comment', '--comment',
                                                    "empeira:#{'a' * 64}", '-j', 'ACCEPT']])
    expect(rules.first.last).to include('-s', '10.210.40.0/24')
  end

  it 'does not duplicate existing rules and removes only the exact owned rule' do
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(['', '', status])
    expect(EmpeiraGateway).not_to receive(:command)
    described_class.reconcile('iptables', 'apply', 'raw', 'PREROUTING', ['owned'])
  end

  it 'fails closed when attachment rules are missing or the Docker backend is unrecognized' do
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return(['', '', status])
    expect { described_class.backend }.to raise_error(/Cannot identify Docker/)
    expect { described_class.reconcile('iptables', 'check', 'raw', 'PREROUTING', ['owned']) }
      .to raise_error(/attachment rules missing/)
  end
end
