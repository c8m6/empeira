# frozen_string_literal: true

RSpec.describe Empeira::Updates::Images do
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:runtime) { double('runtime', architecture: 'amd64', refresh_image: :updated) }
  let(:events) { [] }
  let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }
  let(:updater) { described_class.new(context: context, runtime: runtime, progress: progress) }
  let(:state) { { 'runtime' => context.container_engine, 'nodes' => {} } }

  before do
    allow(runtime).to receive(:with_image_updates).and_yield
    # Inventory validation itself is covered by Store/Node contracts; this fixture tests catalog selection only.
    store = instance_double(Empeira::Infrastructure::Store, load: state)
    allow(Empeira::Infrastructure::Store).to receive(:new).and_return(store)
  end

  it 'selects the default and used container variants without changing recorded nodes or services' do
    state['nodes'] = {
      'old' => { 'provider' => 'container', 'os' => 'rocky', 'version' => '9' },
      'duplicate' => { 'provider' => 'container', 'os' => 'rocky', 'version' => '9' },
      'vm' => { 'provider' => 'vm', 'os' => 'almalinux', 'version' => '8' }
    }
    original = Marshal.dump(state)
    calls = []
    allow(runtime).to receive(:refresh_image) { |image, **|
      calls << image
      :updated
    }
    progress.run('Updating images...') { updater.refresh }
    expect(events.map(&:message)).to include('Ubuntu 24.04 node image — updated (11/12)',
                                             'Rocky 9 node image — updated (12/12)')
    expect(calls.grep(/empeira-node/).size).to eq(2)
    expect(calls).to include(context.configuration.dig('images', 'dns').then { |image|
      Empeira::Images::Configuration.reference(image)
    })
    expect(calls.grep(/empeira-r10k/).size).to eq(1)
    expect(Marshal.dump(state)).to eq(original)
  end

  it 'counts completed artifacts with readable labels and preserves failure progress' do
    catalog = 10.times.map { |index| { label: "Fixture #{index}", image: "registry.example/test:#{index}" } }
    allow(updater).to receive(:catalog).and_return(catalog)
    allow(runtime).to receive(:refresh_image).with('registry.example/test:4')
                                             .and_raise(Empeira::Providers::ExecutionError, 'error: download failed')
    expect do
      progress.run('Updating images...') { updater.refresh }
    end.to raise_error(Empeira::Providers::ExecutionError, %r{Fixture 4.*registry.example/test:4.*download failed})
    expect(events.last).to have_attributes(percent: 40, state: :failed, message: 'Failed: Fixture 4 (4/10)')
    expect(events.map(&:percent)).not_to include(100)
  end

  it 'fails before refreshing artifacts for a workspace owned by another runtime' do
    state['runtime'] = 'docker'
    expect(runtime).not_to receive(:refresh_image)
    expect { updater.refresh }.to raise_error(Empeira::Error, /owning runtime/)
  end

  it 'counts unchanged artifacts as completed without reporting a pull' do
    allow(runtime).to receive(:refresh_image).and_return(:unchanged)
    progress.run('Updating images...') { updater.refresh }
    expect(events.map(&:message)).to include('Browser — unchanged (3/11)',
                                             'Ubuntu 24.04 node image — unchanged (11/11)')
    expect(events.last).to have_attributes(percent: 100, state: :complete)
    expect(events.map(&:message).join).not_to include('updating (')
  end

  it 'updates the same utility artifacts that the control plane consumes' do
    configured = Empeira::Images::Configuration.artifact(context.configuration.dig('images', 'proxy'))
    expect(updater.send(:catalog).find { |entry| entry[:label] == 'Squid proxy' }[:image]).to eq(configured[:image])
    plan = Empeira::ControlPlane::Plan.new(context: context)
    relay = Empeira::ControlPlane::Browser.new(plan).relay_image
    expect(updater.send(:catalog).find { |entry| entry[:label] == 'Service relay' }[:image]).to eq(relay[:image])
    direct = plan.gateway_artifact
    expect(updater.send(:catalog).find { |entry| entry[:label] == 'Workspace gateway' }[:image])
      .to eq(direct[:image])
  end
end
