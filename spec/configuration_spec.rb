# frozen_string_literal: true

RSpec.describe Empeira::Configuration do
  def load_config(overrides = {})
    described_class::Loader.new(project_path: @directory).load(overrides: overrides)
  end

  def write_config(text)
    File.write(File.join(@directory, '.empeira.yaml'), text)
  end

  it 'names the disposable helper images.r10k and rejects images.modules' do
    expect(load_config.dig('images', 'r10k', 'build')).to eq('modules/Containerfile')
    File.write(File.join(@directory, '.empeira.yaml'), 'images: {modules: {build: modules/Containerfile}}')
    expect { load_config }.to raise_error(Empeira::ConfigurationError, /images.modules/)
  end

  it 'loads isolated defaults with an empty project marker' do
    config = load_config
    expect(config['version']).to eq(1)
    expect(config['runtime']).to eq('container_engine' => 'podman')
    expect(config['modules']).to eq('path' => 'modules')
    expect(config['network']).to eq('egress' => [], 'redirects' => [])
    expect(config['node_defaults']).to include('memory' => 1024, 'cpus' => 2)
    expect(config['node_defaults']).not_to have_key('provider')
    expect(config.dig('vm', 'disk')).to eq(30)
    expect(config['node_defaults']).not_to have_key('disk')
    expect(config['puppetdb']['enabled']).to be(true)
    expect(config.dig('browser', 'start_url')).to eq('about:blank')
    expect(config.dig('bootstrap', 'guests', 'ubuntu', '24.04').keys)
      .to contain_exactly('agent_preinstalled', 'destinations')
  end

  it 'accepts the legacy proxy-mode shape for existing projects' do
    write_config('network: {egress: {mode: proxy}}')
    expect(load_config.dig('network', 'egress')).to eq('mode' => 'proxy')
    context = Empeira::Application.new(project_path: @directory).context
    expect(Empeira::ControlPlane::Plan.new(context: context)).to be_proxy
  end

  it 'merges VM disk capacity independently of console configuration' do
    write_config('vm: {disk: 48}')
    expect(load_config.fetch('vm')).to eq('disk' => 48, 'console' => { 'root_password' => 'empeira' })
  end

  [nil, 0, -1, 1.5, '30', true, 2049].each do |size|
    it "rejects invalid vm.disk #{size.inspect}" do
      write_config(YAML.dump('vm' => { 'disk' => size }))
      expect { load_config }.to raise_error(Empeira::ConfigurationError, /vm.disk.*1 to 2048 GiB/)
    end
  end

  it 'overrides the browser start page with an internal URL without changing the browser image' do
    url = 'http://openvoxview.empeira.internal:5000'
    write_config(YAML.dump('browser' => { 'start_url' => url }))
    expect(load_config.fetch('browser')).to eq(
      'start_url' => url,
      'image' => { 'repository' => 'linuxserver/chromium', 'tag' => 'latest' }
    )
  end

  [nil, false, 123, [], '', '   ', "http://test/\0", "http://test/\n", "http://test/\r",
   "http://test/\t", "http://test/\e", "http://test/\u007f", "http://test/\u0085"].each do |value|
    it "rejects invalid browser.start_url #{value.inspect}" do
      write_config(YAML.dump('browser' => { 'start_url' => value }))
      expect { load_config }.to raise_error(Empeira::ConfigurationError, /browser.start_url.*nonempty string/)
    end
  end

  it 'accepts configurable module storage and identifies invalid values by their YAML path' do
    write_config("modules:\n  path: .cache/puppet-modules\n")
    expect(load_config.dig('modules', 'path')).to eq('.cache/puppet-modules')
    write_config("modules:\n  path: ''\n")
    expect { load_config }.to raise_error(Empeira::ConfigurationError, /modules.path/)
  end

  it 'merges project configuration and permitted CLI overrides in order' do
    write_config("version: 1\nnode_defaults:\n  memory: 2048\n  os: debian\n")
    config = load_config('node_defaults' => { 'cpus' => 4 })
    expect(config['node_defaults']).to eq('memory' => 2048, 'cpus' => 4, 'os' => 'debian', 'version' => '24.04',
                                          'init' => 'process')
  end

  it 'accepts and ignores the removed network.internet project key for compatibility' do
    write_config('network: {internet: false}')
    expect(load_config.fetch('network')).to eq('egress' => [], 'redirects' => [])
  end

  it 'does not permit arbitrary CLI configuration overrides' do
    expect { load_config('puppetdb' => { 'enabled' => false }) }
      .to raise_error(Empeira::ConfigurationError, /puppetdb cannot be overridden/)
  end

  {
    'version: 2' => /version.*schema version 1/,
    'version: 1.0' => /version.*schema version 1/,
    'netwrok: {}' => /netwrok.*not a supported/,
    'network: null' => /network must be a mapping/,
    'network: {internet: "true"}' => /network.internet must be a boolean/,
    'runtime: {container_engine: qemu}' => /runtime.container_engine must be one of: podman, docker/,
    'node_defaults: {memory: 0}' => /node_defaults.memory must be a positive integer/,
    'node_defaults: {cpus: -1}' => /node_defaults.cpus must be a positive integer/,
    'node_defaults: {memory: 1.5}' => /node_defaults.memory must be a positive integer/,
    'node_defaults: {cpus: "2"}' => /node_defaults.cpus must be a positive integer/,
    'node_defaults: {os: 12}' => /node_defaults.os must be a non-empty string or null/,
    'node_defaults: {version: 12}' => /node_defaults.version must be a non-empty string or null/,
    'node_defaults: {provider: container}' => /node_defaults.provider.*not a supported/,
    'node_defaults: {disk: 30}' => /node_defaults.disk.*not a supported/,
    'nodes: {host1: {}}' => /nodes.*not a supported/,
    'server: {unknown: true}' => /server.unknown.*not a supported/,
    'bootstrap: {enabled: null}' => /bootstrap.enabled must be a boolean/,
    '[]' => /\$ must be a mapping/,
    'true: false' => /non-string key/,
    'x: [' => /valid YAML/,
    'network: &net {egress: []}\nserver: *net' => /valid YAML/,
    '--- !ruby/object:Object {}' => /valid YAML/
  }.each do |text, message|
    it "rejects invalid configuration #{text.inspect}" do
      write_config(text.gsub('\\n', "\n"))
      expect { load_config }.to raise_error(Empeira::ConfigurationError, message)
    end
  end

  it 'does not hide invalid project data beneath a valid override' do
    write_config('node_defaults: {memory: broken}')
    expect { load_config('node_defaults' => { 'memory' => 2048 }) }
      .to raise_error(Empeira::ConfigurationError, /node_defaults.memory/)
  end

  it 'rejects missing project directories' do
    expect { described_class::Loader.new(project_path: File.join(@directory, 'missing')).load }
      .to raise_error(Empeira::ConfigurationError, /existing directory/)
  end

  it 'deep merges hashes, replaces arrays and scalars, and never shares mutable values' do
    lower = { 'nested' => { 'keep' => 'value', 'array' => [1, 2] }, 'scalar' => 4 }
    higher = { 'nested' => { 'array' => [{ 'new' => 'text' }] }, 'scalar' => nil }
    result = described_class::Merge.call(lower, higher)
    expect(result).to eq('nested' => { 'keep' => 'value', 'array' => [{ 'new' => 'text' }] }, 'scalar' => nil)
    result['nested']['keep'].replace('changed')
    result['nested']['array'][0]['new'].replace('changed')
    expect(lower['nested']['keep']).to eq('value')
    expect(higher['nested']['array'][0]['new']).to eq('text')
  end

  it 'redacts sensitive keys recursively without modifying the source' do
    data = { 'tokens' => 'secret', 'items' => [{ 'private_key' => 'key', 'enabled' => true }] }
    expect(described_class::Display.redact(data))
      .to eq('tokens' => '[REDACTED]', 'items' => [{ 'private_key' => '[REDACTED]', 'enabled' => true }])
    expect(data['tokens']).to eq('secret')
  end
end
