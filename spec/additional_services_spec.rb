# frozen_string_literal: true

require_relative 'support/openvox_view'

RSpec.describe Empeira::Configuration::AdditionalServices do
  include OpenVoxViewFixture

  let(:service) do
    { 'name' => 'custom-service', 'image' => { 'repository' => 'registry.example:5000/team/service', 'tag' => '1.2' },
      'environment' => { 'KEY' => 'value' }, 'command' => ['serve', '--port', '8080'] }
  end

  def configuration(services)
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('containers' => { 'additional' => JSON.parse(JSON.generate(services)) }))
    Empeira::Application.new(project_path: @directory).context
  end

  it 'accepts empty, one and multiple services with private image registries and literal arguments' do
    [[], [service], [service, service.merge('name' => 'other')]].each do |entries|
      plan = Empeira::ControlPlane::Plan.new(context: configuration(entries))
      expect(plan.additional_services.keys).to eq(entries.map { |entry| entry['name'] })
      entries.each do |entry|
        definition = plan.definitions.fetch(entry['name'])
        expect(definition.options).to include('image' => 'registry.example:5000/team/service:1.2',
                                              'network' => plan.network)
        expect(definition.options['environment']).to include('KEY' => 'value', 'HTTP_PROXY' => '', 'HTTPS_PROXY' => '')
        expect(definition.options).not_to have_key('ports')
      end
    end
  end

  it 'accepts the OpenVox View example with string environment values and internal DNS only' do
    plan = Empeira::ControlPlane::Plan.new(context: configuration([openvox_view]))
    definition = plan.definitions.fetch('openvoxview')
    selected = Empeira::Images::Configuration.reference(openvox_view.fetch('image'))
    expect(definition.options).to include('image' => selected,
                                          'hostname' => 'openvoxview.empeira.internal', 'network' => plan.network)
    expect(definition.options.fetch('environment')).to include(openvox_view.fetch('environment'))
    expect(definition.options.fetch('environment').values).to all(be_a(String))
    expect(definition.options.keys & %w[ports mounts]).to be_empty
    expect(definition.options['command']).to eq([])
    arguments = Empeira::Runtime::ServiceArguments.new(definition).build
    expect(arguments).to include('PUPPETDB_TLS=false', 'PORT=5000', 'LISTEN=0.0.0.0')
    expect(arguments.last).to eq(selected)
    expect(arguments).not_to include('--publish', '--publish-all')
  end

  ['', 'Upper', '-bad', 'bad-', 'two.words', 'a' * 64, *described_class::RESERVED].each do |name|
    it "rejects invalid or reserved service name #{name.inspect}" do
      expect { configuration([service.merge('name' => name)]) }
        .to raise_error(Empeira::ConfigurationError, /containers.additional\[0\].name/)
    end
  end

  it 'rejects duplicates and the broad Compose surface' do
    expect { configuration([service, service]) }.to raise_error(Empeira::ConfigurationError, /collides/)
    %w[volumes privileged capabilities devices ports network restart depends_on healthcheck].each do |field|
      expect { configuration([service.merge(field => true)]) }.to raise_error(Empeira::ConfigurationError)
    end
  end

  it 'requires repository/tag and string environment and command entries without leaking values' do
    [{ 'image' => { 'repository' => 'test' } }, { 'image' => { 'repository' => 'test', 'tag' => 1 } },
     { 'image' => { 'repository' => 'test', 1 => 'bad' } },
     { 'environment' => { 'BAD=KEY' => 'secret-value' } }, { 'environment' => { 'KEY' => 2 } },
     { 'command' => 'secret-value' }, { 'command' => ["bad\0value"] }].each do |override|
      expect { configuration([service.merge(override)]) }.to raise_error(Empeira::ConfigurationError) do |error|
        expect(error.message).not_to include('secret-value')
      end
    end
  end

  it 'fingerprints image, command and environment changes without persisting environment secrets' do
    initial = Empeira::Infrastructure::Definition.new(context: configuration([service]))
    %w[environment command image].each do |key|
      changed = Marshal.load(Marshal.dump(service))
      case key
      when 'environment' then changed[key]['KEY'] = 'private-secret'
      when 'command' then changed[key] << '--verbose'
      when 'image' then changed[key]['tag'] = '2'
      end
      definition = Empeira::Infrastructure::Definition.new(context: configuration([changed]))
      expect(definition.fingerprint).not_to eq(initial.fingerprint)
      expect(JSON.generate(definition.metadata)).not_to include('private-secret')
    end
  end
end
