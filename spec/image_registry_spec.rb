# frozen_string_literal: true

RSpec.describe 'Image registry resolution' do
  [
    ['library/postgres', nil, 'docker.io/library/postgres'],
    ['library/postgres', 'registry.example.org', 'registry.example.org/library/postgres'],
    ['linuxserver/chromium', 'registry.example.org:5000', 'registry.example.org:5000/linuxserver/chromium'],
    ['registry.example/team/server', 'registry.example.org', 'registry.example/team/server'],
    ['docker.io/library/postgres', 'registry.example.org', 'docker.io/library/postgres'],
    ['localhost:5000/team/image', 'registry.example.org', 'localhost:5000/team/image']
  ].each do |repository, registry, expected|
    it "resolves #{repository} with registry #{registry.inspect}" do
      expect(Empeira::Images::Configuration.reference({ 'repository' => repository, 'tag' => 'latest' },
                                                      registry: registry))
        .to eq("#{expected}:latest")
    end
  end

  it 'preserves exact and digest references' do
    resolver = Empeira::Images::Configuration
    expect(resolver.reference({ 'reference' => 'exact/image:1' }, registry: 'cache.example')).to eq('exact/image:1')
    digest = "sha256:#{'a' * 64}"
    expect(resolver.reference({ 'repository' => 'library/ruby', 'digest' => digest }, registry: 'cache.example'))
      .to eq("cache.example/library/ruby@#{digest}")
  end

  [true, '', 'https://registry.example.org', 'http://registry.example.org', 'registry.example.org/path',
   'user:pass@registry.example.org', 'registry.example.org:0',
   'registry.example.org:65536', "registry.example.org\n"].each do |registry|
    it "rejects invalid images.registry #{registry.inspect}" do
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('images' => { 'registry' => registry }))
      expect { Empeira::Application.new(project_path: @directory).context }
        .to raise_error(Empeira::ConfigurationError, /images.registry/)
    end
  end

  it 'resolves browser, node, utility and multi-stage builder bases through the same default registry' do
    original = Empeira::Application.new(project_path: @directory).context
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('images' => { 'registry' => 'cache.example:5000' }))
    context = Empeira::Application.new(project_path: @directory).context
    config = context.configuration
    plan = Empeira::ControlPlane::Plan.new(context: context)
    expect(Empeira::ControlPlane::Browser.new(plan).definitions.fetch('browser').options['image'])
      .to eq(Empeira::Images::Configuration.reference(config.dig('browser', 'image'),
                                                      registry: config.dig('images', 'registry')))
    expected = Empeira::Images::Configuration.reference(original.configuration.dig('images', 'server'))
    expect(plan.definitions.fetch('server').options['image']).to eq(expected)
    %w[relay proxy r10k].each do |key|
      configured = Empeira::Images::Configuration.artifact(config.dig('images', key),
                                                           registry: config.dig('images', 'registry'))
      baseline = Empeira::Images::Configuration.artifact(original.configuration.dig('images', key))
      expect(Empeira::Images::Recipe.bases(configured.fetch(:recipe)).values).to all(start_with('cache.example:5000/'))
      expect(Empeira::Images::Recipe.bases(baseline.fetch(:recipe)).values).to all(start_with('docker.io/'))
      expect(configured.fetch(:image)).not_to eq(baseline.fetch(:image))
    end
    installer = Empeira::Modules::Image.new(config.dig('images', 'r10k'), registry: config.dig('images', 'registry'))
    baseline = Empeira::Modules::Image.new(original.configuration.dig('images', 'r10k'))
    expected_bases = Empeira::Images::Recipe.bases(baseline.recipe).transform_values do |base|
      base.sub('docker.io/', 'cache.example:5000/')
    end
    expect(Empeira::Images::Recipe.bases(installer.recipe)).to eq(expected_bases)
    adapter = Empeira::Network::Peer::AdapterImage.new(context: context)
    expect(Empeira::Images::Recipe.bases(adapter.recipe).values)
      .to eq([Empeira::Images::Configuration.reference(config.dig('images', 'network_adapter_builder'),
                                                       registry: config.dig('images', 'registry'))])
    request = Empeira::Node::RunRequest.from_config(hostname: 'node', provider: 'container', config: config)
    node = Empeira::Node::Image.new(config: config, request: request, architecture: 'amd64')
    selected_node = config.dig('images', 'nodes', request.os, request.version).except('build')
    expected_node = Empeira::Images::Configuration.reference(selected_node, registry: config.dig('images', 'registry'))
    expect(Empeira::Images::Recipe.bases(node.recipe).values).to eq([expected_node])
  end

  it 'does not rewrite explicitly hosted controlled bases or treat scratch as remote' do
    recipe = "ARG EMPEIRA_BASE_ONE=ghcr.io/example/image:1\nFROM ${EMPEIRA_BASE_ONE}\nFROM scratch\n"
    expect(Empeira::Images::Recipe.render(recipe, registry: 'cache.example')).to eq(recipe)
    expect(Empeira::Images::Recipe.bases(recipe)).to eq('EMPEIRA_BASE_ONE' => 'ghcr.io/example/image:1')
  end

  it 'keeps all configured agent packages and credentials out of node images' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('agent' => { 'package' => 'puppet-agent' }))
    config = Empeira::Application.new(project_path: @directory).context.configuration
    request = Empeira::Node::RunRequest.from_config(hostname: 'node.example.net', provider: 'container', config: config)
    recipe = Empeira::Node::Image.new(config: config, request: request, architecture: 'amd64').recipe
    expect(recipe).not_to include('puppet-agent', 'openvox-agent', 'EMPEIRA_AGENT_REPO_PASSWORD')
    expect(recipe).to include('openssh-server')
  end

  it 'keeps RPM node images independent of the selected agent package' do
    config = Empeira::Application.new(project_path: @directory).context.configuration
    request = Empeira::Node::RunRequest.from_config(hostname: 'node.example.net', provider: 'container',
                                                    config: config).with(os: 'rocky', version: '9')
    recipe = Empeira::Node::Image.new(config: config, request: request, architecture: 'amd64').recipe
    expect(recipe).not_to include('puppet-agent', 'openvox-agent', 'EMPEIRA_AGENT_REPO_PASSWORD')
    expect(recipe).to include('dnf install -y ca-certificates')
  end
end
