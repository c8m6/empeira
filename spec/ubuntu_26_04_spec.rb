# frozen_string_literal: true

require 'empeira/completion/catalog'

RSpec.describe 'Ubuntu 26.04 node support' do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:config) { app.context.configuration }

  it 'defaults to Ubuntu 26.04 while exposing all three LTS versions to completion' do
    defaults = Empeira::Configuration::Loader.new(project_path: @directory).load_defaults
    expect(defaults.fetch('node_defaults')).to include('os' => 'ubuntu', 'version' => '26.04')
    Dir.chdir(@directory) do
      words = ['node', 'run', 'host', '--version', '']
      expect(Empeira::Completion::Catalog.new.candidates(words, words.size - 1)).to include('22.04', '24.04', '26.04')
    end
  end

  %w[amd64 arm64].each do |architecture|
    it "resolves reviewed container, VM and agent sources for #{architecture}" do
      %w[container vm].each do |provider|
        request = Empeira::Node::RunRequest.from_config(hostname: 'ubuntu-test', provider: provider, config: config)
        expect(request.version).to eq('26.04')
        image = Empeira::Node::Image.new(config: config, request: request, architecture: architecture)
        reference = Empeira::Images::Configuration.reference(config.dig('images', 'nodes', 'ubuntu', '26.04'))
        expect(image.recipe).to include(reference, 'systemd', 'sudo', 'dnsutils')
      end
      descriptor = config.dig('images', 'nodes', 'ubuntu', '26.04', 'vm')
      expected = descriptor.fetch('url').gsub('{architecture}', architecture)
      checksum = Digest::SHA256.hexdigest('synthetic cloud image')
      source = Empeira::VM::ImageSource.new(config: config, fetch_text: lambda { |url|
        expect(url).to eq(descriptor.fetch('checksum_url'))
        "#{checksum} *#{URI(expected).path.split('/').last}\n"
      })
      resolved = source.resolve(distribution: 'ubuntu', version: '26.04', architecture: architecture)
      expect(resolved.url).to eq(expected)
      expect(resolved.identity.checksum).to eq(checksum)
      requirements = Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '26.04',
                                                            architecture: architecture)
      expect(requirements.repository).to eq(config.dig('agent', 'install', 'repositories', 'ubuntu26.04'))
      expect(requirements.repository.fetch('sha256')).to match(/\A[a-f0-9]{64}\z/)
      expect(requirements.agent.fetch('version')).to eq(config.dig('agent', 'version'))
      target = Empeira::Agent::Target.new(os: 'ubuntu', release: '26.04', architecture: architecture)
      expect(target.expand('$suite')).to eq('resolute')
      expect(target.native_architecture).to eq(architecture)
    end
  end

  it 'validates VM source fragments and preserves deep merge of a partial override' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(
                                                         'images' => { 'nodes' => { 'ubuntu' => { '26.04' => { 'vm' => {
                                                           'url' => 'https://images.example.test/guest-{architecture}.img'
                                                         } } } } }
                                                       ))
    overridden = app.context.configuration.dig('images', 'nodes', 'ubuntu', '26.04', 'vm')
    expect(overridden.fetch('checksum_url')).to start_with('https://')
    %w[http://images.example.test/image https://user:secret@images.example.test/image
       https://images.example.test/image#x].each do |url|
      fragment = { 'images' => { 'nodes' => { 'ubuntu' => { '26.04' => { 'vm' => { 'url' => url } } } } } }
      expect { Empeira::Configuration::Schema.new.validate_fragment!(fragment) }
        .to raise_error(Empeira::ConfigurationError, /images.nodes.ubuntu.26.04.vm.url/)
    end
  end
end
