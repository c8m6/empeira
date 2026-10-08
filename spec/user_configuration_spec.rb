# frozen_string_literal: true

require 'empeira/cli/main'

RSpec.describe 'Host-local user configuration' do
  let(:home) { Pathname(@directory).join('user-home') }
  let(:locations) { Empeira::Platform::Locations.new(home: home, environment: {}) }
  let(:user_file) { home.join('.empeira.yaml') }
  let(:loader) { Empeira::Configuration::Loader.new(project_path: @directory, locations: locations) }

  before { home.mkpath }

  it 'silently accepts a missing or empty user file' do
    expect { loader.load }.not_to output.to_stderr
    baseline = loader.load
    user_file.write('')
    expect(loader.load).to eq(baseline)
  end

  it 'merges defaults, project, user and explicit CLI preferences in order' do
    project = { 'runtime' => { 'container_engine' => 'podman' }, 'images' => { 'registry' => 'project.example' },
                'node_defaults' => { 'memory' => 2048 } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(project))
    user_file.write(YAML.dump('runtime' => { 'container_engine' => 'docker' },
                              'images' => { 'registry' => 'cache.example:5000' }))
    config = loader.load
    expect(config.dig('runtime', 'container_engine')).to eq('docker')
    expect(config.dig('images', 'registry')).to eq('cache.example:5000')
    expect(config.dig('images', 'postgres')).to eq(loader.load_defaults.dig('images', 'postgres'))
    expect(config.dig('node_defaults', 'memory')).to eq(2048)
    expect(loader.load(overrides: { 'runtime' => { 'container_engine' => 'podman' } })
                 .dig('runtime', 'container_engine')).to eq('podman')
    expect(YAML.safe_load_file(File.join(@directory, '.empeira.yaml')).dig('images', 'registry'))
      .to eq('project.example')
  end

  it 'allows an explicit null registry to restore Docker Hub while preserving project mappings' do
    File.write(File.join(@directory, '.empeira.yaml'), 'images: {registry: project.example}')
    user_file.write('images: {registry: null}')
    config = loader.load
    expect(Empeira::Images::Configuration.reference(config.dig('images', 'postgres'),
                                                    registry: config.dig('images', 'registry')))
      .to eq(Empeira::Images::Configuration.reference(loader.load_defaults.dig('images', 'postgres')))
  end

  %w[unknown server puppetdb modules hiera eyaml network proxy node_defaults containers browser
     requirements bootstrap dns vm version].each do |section|
    it "rejects user-level #{section} settings with the source and offending path" do
      user_file.write(YAML.dump(section => { 'type' => 'example' }))
      expect { loader.load }.to raise_error(Empeira::ConfigurationError,
                                            /#{Regexp.escape(user_file.to_s)}.*#{section}.*not allowed/)
    end
  end

  %w[providers nodes agents username password token auth credentials registry_credentials auth_file].each do |key|
    it "rejects user images.#{key} instead of admitting project or credential configuration" do
      user_file.write(YAML.dump('images' => { key => 'synthetic' }))
      expect { loader.load }.to raise_error(Empeira::ConfigurationError, /images.#{key}.*not allowed/)
    end
  end

  ["runtime: &r {container_engine: docker}\nimages: *r", '!ruby/object:Object {}',
   'runtime: {container_engine: docker, container_engine: podman}', '[]', "---\n{}\n---\n{}",
   'images: {registry: "cache.example\\u001b"}', '"images\\u001b": {}'].each do |document|
    it "rejects unsafe or malformed user YAML #{document.inspect}" do
      user_file.write(document)
      expect { loader.load }.to raise_error(Empeira::ConfigurationError)
    end
  end

  %w[linux darwin].each do |os|
    it "uses the platform home abstraction on #{os}, including Linux semantics on WSL" do
      facts = Empeira::Platform::Facts.new(host_os: os, host_cpu: 'x86_64')
      places = Empeira::Platform::Locations.new(facts: facts, home: home, environment: {})
      expect(places.user_configuration).to eq(user_file)
    end
  end

  it 'shows effective non-sensitive host preferences through config show' do
    user_file.write('runtime: {container_engine: docker}\nimages: {registry: cache.example}'.gsub('\\n', "\n"))
    allow(Dir).to receive(:home).and_return(home.to_s)
    Dir.chdir(@directory) do
      expect { Empeira::CLI::Main.start(%w[config show]) }
        .to output(/container_engine: docker.*registry: cache.example/m).to_stdout
    end
  end
end
