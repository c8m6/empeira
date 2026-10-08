# frozen_string_literal: true

RSpec.describe 'Reproducible image defaults and explicit project selections' do
  def load(fragment = {})
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(fragment))
    Empeira::Application.new(project_path: @directory).context.configuration
  end

  %w[server puppetdb postgres].each do |component|
    it "executes the default #{component} by digest and permits tag/repository overrides without inherited pins" do
      config = load
      image = config.fetch('images').fetch(component)
      expect(image.fetch('digest')).to match(/\Asha256:[a-f0-9]{64}\z/)
      expect(Empeira::Images::Configuration.reference(image)).to end_with("@#{image.fetch('digest')}")
      overridden = load('images' => { component => { 'repository' => 'registry.example/custom', 'tag' => '1' } })
      selected = overridden.fetch('images').fetch(component)
      expect(selected).not_to have_key('digest')
      expect(Empeira::Images::Configuration.reference(selected)).to eq('registry.example/custom:1')
      tag_only = load('images' => { component => { 'tag' => 'custom' } }).fetch('images').fetch(component)
      expect(tag_only).not_to have_key('digest')
      expect(Empeira::Images::Configuration.reference(tag_only)).to end_with(':custom')
    end
  end

  it 'uses an explicit digest even when a descriptive tag is also configured' do
    config = load('images' => { 'server' => { 'tag' => 'descriptive', 'digest' => "sha256:#{'b' * 64}" } })
    expect(Empeira::Images::Configuration.reference(config.dig('images', 'server'))).to end_with("@sha256:#{'b' * 64}")
  end

  it 'rejects conflicting reference fields in the same source instead of silently ignoring them' do
    expect do
      load('images' => { 'server' => { 'reference' => 'registry.example/server:1', 'digest' => "sha256:#{'a' * 64}" } })
    end
      .to raise_error(Empeira::ConfigurationError, /images.server.reference cannot be combined/)
  end

  it 'replaces inherited reference/build selections when a new repository selection is explicit' do
    lower = { 'images' => { 'server' => { 'reference' => 'registry.example/server:1' } } }
    higher = { 'images' => { 'server' => { 'repository' => 'registry.example/server', 'tag' => '2' } } }
    value = Empeira::Configuration::Merge.call(lower, higher).dig('images', 'server')
    expect(value).not_to have_key('reference')
    expect(Empeira::Images::Configuration.reference(value)).to eq('registry.example/server:2')
  end

  it 'includes digest changes in only the affected service fingerprints' do
    initial = load
    original = Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
    previous = original.fingerprints
    updated = load('images' => { 'server' => { 'digest' => "sha256:#{'b' * 64}" } })
    current = Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
    expect(current.fingerprints.fetch('server')).not_to eq(previous.fetch('server'))
    expect(current.fingerprints.except('server')).to eq(previous.except('server'))
    expect(updated.fetch('agent')).to eq(initial.fetch('agent'))
  end
end
