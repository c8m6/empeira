# frozen_string_literal: true

require_relative 'support/runtime_execution'

RSpec.describe 'Project Empeira version requirements' do
  # These examples isolate the existing network/version contracts from service orchestration.
  before do
    plane = instance_double(Empeira::ControlPlane::Controller, up: false, down: false, status: {}, preflight: nil)
    allow(Empeira::ControlPlane::Controller).to receive(:new).and_return(plane)
  end
  def app(requirement, version: '0.4.0')
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('requirements' => { 'empeira' => requirement }))
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {})
    Empeira::Application.new(project_path: @directory, runner: runner,
                             build_info: Empeira::BuildInfo.new(version: version),
                             locations: locations)
  end

  let(:runner) { RuntimeExecution.new }

  ['>= 0.1.0', '>= 0.4.0, < 1.0', '~> 0.4', nil].each do |requirement|
    it "permits a compatible release with #{requirement.inspect}" do
      expect(app(requirement).infrastructure.up.changed).to be(true)
    end
  end

  ['>= 0.5', '< 0.4', '>= 0.1, < 0.4'].each do |requirement|
    it "refuses infrastructure mutations for #{requirement.inspect} before runtime execution" do
      application = app(requirement)
      expect { application.infrastructure.up }.to raise_error(Empeira::Error, /self-update/)
      expect { application.infrastructure.down }.to raise_error(Empeira::Error, /Required:.*Installed:/m)
      expect(runner.calls).to be_empty
      expect(application.context.locations.workspace(application.context.workspace)).not_to exist
      expect(application.infrastructure.status['Version requirement']).to eq('incompatible')
      expect(Empeira::Configuration::Loader.new(project_path: @directory).load).to be_a(Hash)
    end
  end

  ['', 'latest', '=> 1', '>= 1,', ',< 2', 123, []].each do |value|
    it "rejects malformed requirement #{value.inspect} with its YAML path" do
      expect { app(value) }.to raise_error(Empeira::ConfigurationError, /requirements.empeira/)
    end
  end

  it 'does not treat a development build as a released semantic version' do
    application = app('>= 0.1', version: 'development')
    expect(application.infrastructure.status['Version requirement']).to include('unverifiable')
    expect { application.infrastructure.up }.to raise_error(Empeira::Error, /Installed: development/)
    expect(runner.mutations).to be_empty
  end

  it 'permits local development when no project requirement is set' do
    expect(app(nil, version: 'development').infrastructure.up.changed).to be(true)
  end
end
