# frozen_string_literal: true

RSpec.describe Empeira::Agent::Acquisition do
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'shared-home'), environment: {}) }
  let(:app) { Empeira::Application.new(project_path: @directory, locations: locations) }
  let(:runtime) do
    instance_double(Empeira::Runtime::Docker, check_available!: nil, architecture: 'amd64',
                                              ensure_image: nil, image_architecture: 'amd64')
  end
  let(:requirements) do
    Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04', architecture: 'amd64')
  end
  let(:resolver) do
    instance_double(Empeira::Node::AgentRepository, prepare_keys: nil, public_keys: [],
                                                    resolve: { 'url' => 'https://packages.example.org/agent.deb',
                                                               'version' => '1.2.3-1noble' },
                                                    inspect_package: { 'version' => '1.2.3-1noble',
                                                                       'architecture' => 'amd64' })
  end
  let(:download) { instance_double(Empeira::Agent::Download, authorize: nil) }
  let(:content) { "!<arch>\nsynthetic-agent-package" }
  let(:acquisition) { described_class.new(context: app.context, runtime: runtime) }

  def configure(method: 'repository', cache: true)
    install = { 'method' => method }
    if method == 'repository'
      install['apt'] = { 'default' => { 'url' => 'https://packages.example.org/apt' } }
    else
      install['packages'] = { 'ubuntu24.04' => { 'amd64' => { 'url' => 'https://packages.example.org/agent.deb' } } }
    end
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('agent' => { 'package' => 'synthetic-agent', 'version' => '1.2.3',
                                      'cache' => { 'enabled' => cache }, 'install' => install }))
  end

  before do
    configure
    allow(runtime).to receive(:with_agent_helper).and_yield({ 'id' => 'owned-helper' })
    allow(Empeira::Node::AgentRepository).to receive(:new).and_return(resolver)
    allow(Empeira::Agent::Download).to receive(:new).and_return(download)
    allow(download).to receive(:fetch) { |_, path, **| File.binwrite(path, content, perm: 0o600) }
  end

  %w[repository package].each do |method|
    it "uses one acquisition and cache path for #{method}, including different workspaces" do
      configure(method: method)
      path = acquisition.with_package(requirements, &:path)
      other_project = File.join(@directory, 'another-workspace')
      initialize_project(other_project)
      FileUtils.cp(File.join(@directory, '.empeira.yaml'), File.join(other_project, '.empeira.yaml'))
      other = Empeira::Application.new(project_path: other_project, locations: locations)
      other_requirements = Empeira::VM::BootstrapRequirements.new(context: other.context, os: 'ubuntu',
                                                                  version: '24.04', architecture: 'amd64')
      described_class.new(context: other.context, runtime: runtime).with_package(other_requirements) do |artifact|
        expect(artifact.path).to eq(path)
      end
      expect(download).to have_received(:fetch).once
      expect(runtime).to have_received(:with_agent_helper).once
      expect(resolver).to have_received(:resolve).exactly(method == 'repository' ? 1 : 0).times
    end

    it "uses transient acquisition for #{method} when disabled and cleans after an installation failure" do
      configure(method: method, cache: false)
      first = acquisition.with_package(requirements, &:path)
      expect(first).not_to exist
      expect do
        acquisition.with_package(requirements) { raise Empeira::Error, 'dependency unavailable' }
      end.to raise_error(Empeira::Error, /dependency unavailable/)
      expect(download).to have_received(:fetch).twice
      expect(locations.cache.join('agents')).not_to exist
    end
  end

  it 'requires current artifact access for authenticated cache reuse and never persists credentials' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'synthetic-username'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-password'
    acquisition.with_package(requirements) { nil }
    acquisition.with_package(requirements) { nil }
    expect(download).to have_received(:authorize).with('https://packages.example.org/agent.deb').once
    records = locations.cache.join('agents').glob('**/*').select(&:file?).map(&:binread).join
    expect(records).not_to include('synthetic-username', 'synthetic-password', 'Authorization')
    allow(download).to receive(:authorize).and_raise(Empeira::Error, 'access denied')
    expect { acquisition.with_package(requirements) { raise 'must not install' } }
      .to raise_error(Empeira::Error, /access denied/)
    expect(download).to have_received(:fetch).once
  end

  it 'rejects a native repository/artifact version mismatch before publication or guest installation' do
    allow(resolver).to receive(:inspect_package).and_return('version' => '1.2.3-2noble', 'architecture' => 'amd64')
    expect { acquisition.with_package(requirements) { raise 'must not install' } }
      .to raise_error(Empeira::Error, /differs from its native repository metadata/)
    expect(locations.cache.join('agents/refs').children).to be_empty
  end

  it 'checks helper prerequisites without acquisition before VM state mutation' do
    allow(runtime).to receive(:architecture).and_return('arm64')
    expect { acquisition.preflight!(requirements) }.to raise_error(Empeira::Error, /architecture differs/)
    expect(runtime).not_to have_received(:ensure_image)
    expect(runtime).not_to have_received(:with_agent_helper)
    expect(locations.cache.join('agents')).not_to exist
  end
end
