# frozen_string_literal: true

RSpec.describe 'Control-plane configuration and service contracts' do
  def plan(config = {}, project_path = @directory)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: project_path).context)
  end

  it 'defaults to configured OpenVox tags, shared DNS, no proxy and no host ports' do
    value = plan
    expected = Empeira::Images::Configuration.reference(value.config.dig('images', 'server'))
    expect(value.definitions.fetch('server').options.fetch('image')).to eq(expected)
    expect(value.proxy?).to be(false)
    value.definitions.each_value do |definition|
      expect(definition.options['image']).to match(/:(?:[0-9]|[a-f0-9]{64}\z)/)
      expect(definition.options).not_to have_key('ports')
    end
    expect(value.definitions['server'].options['environment']).to include('AUTOSIGN' => 'false', 'HTTP_PROXY' => '',
                                                                          'HTTPS_PROXY' => '', 'ALL_PROXY' => '')
    expect(value.files.send(:jetty)).to eq("[jetty]\nhost = 0.0.0.0\nport = 8080\n")
    expect(value.files.configuration.to_s).not_to match(/ssl-|client-auth|certificate-allowlist/)
    expect(value.definitions['puppetdb'].options['mounts'].join).not_to include('empeira-tls')
    relay_key = Empeira::Server::RelayCertificate.new(context: value.context).path('key.pem')
    expect(value.definitions['puppetdb'].options['mounts'].join).to include(relay_key)
    %w[puppetdb-backend dns server].each do |key|
      expect(value.definitions.fetch(key).options.fetch('mounts').join).not_to include(relay_key)
    end
    expect(relay_key).not_to start_with("#{value.files.directory}/")
    expected = Empeira::Images::Configuration.reference(value.config.dig('images', 'puppetdb'))
    expect(value.definitions['puppetdb-backend'].options['image']).to eq(expected)
    expect(value.definitions['puppetdb-backend'].options['ports']).to be_nil
    expect(value.definitions['puppetdb'].options['ports']).to be_nil
  end

  it 'configures OpenVox through the service and certificate contract' do
    value = plan
    expect(value.definitions.keys).to match_array(%w[gateway dns server postgres puppetdb-backend puppetdb])
    expect(value.definitions['server'].options['hostname']).to eq('server.empeira.internal')
    url_key = value.server_runtime.environment_keys.fetch('puppetdb_server_urls')
    expect(value.definitions['server'].options['environment'][url_key])
      .to eq('')
    expected = Empeira::Images::Configuration.reference(value.config.dig('images', 'server'))
    expect(value.definitions['server'].options['image']).to eq(expected)
    expect(value.definitions['server'].options).not_to have_key('recipe')
    expect(value.definitions['server'].options['mounts'].join)
      .to include('dst=/empeira-server/puppetdb.conf,readonly')
    expect(value.definitions['server'].options['command'])
      .to include(value.server_runtime.startup.fetch('entrypoint'),
                  value.server_runtime.paths.fetch('puppetdb_config'))
    expect(value.files.configuration.fetch('server-puppetdb.conf')).to include(
      'server_urls = https://puppetdb.empeira.internal:8081', 'verify_client_certificate = false'
    )
    expect(value.definitions['puppetdb'].options.fetch('image')).not_to eq(value.definitions['server'].options['image'])
    expect(value.volumes['ca'].key).to eq('openvox-ca')
  end

  it 'excludes observed IPs, secrets, node defaults and application versions from desired service fingerprints' do
    value = plan
    expect(value.definitions(dns: '172.20.0.2').transform_values(&:fingerprint))
      .to eq(value.definitions(dns: '172.21.0.2').transform_values(&:fingerprint))
    before = value.fingerprints
    expect(plan('node_defaults' => { 'memory' => 8192 }).fingerprints).to eq(before)
  end

  it 'mounts uncommitted control code and additional Hiera directories read-only at documented paths' do
    Dir.mkdir(File.join(@directory, 'hiera-data'))
    alias_path = File.join(@directory, 'repository-alias')
    File.symlink(@directory, alias_path)
    mounts = plan(
      { 'hiera' => { 'mounts' => [{ 'source' => 'hiera-data', 'type' => 'module',
                                    'name' => 'hieradata' }] } }, alias_path
    ).repository_mounts
    root = Pathname(@directory).realpath
    destination = '/etc/puppetlabs/code/environments/production/modules/hieradata'
    expect(mounts).to include("type=bind,src=#{root},dst=/empeira-control,readonly",
                              "type=bind,src=#{root}/hiera-data,dst=#{destination},readonly")
  end

  {
    'server.type' => { 'server' => { 'type' => 'custom' } },
    'server.environment' => { 'server' => { 'environment' => '../bad' } },
    'hiera.mounts.0.source' => { 'hiera' => { 'mounts' => [{ 'source' => 'absent', 'type' => 'module',
                                                             'name' => 'data', 'required' => true }] } },
    'proxy.dns_servers' => { 'proxy' => { 'dns_servers' => ['resolver;bad'] } }
  }.each do |path, config|
    it "rejects invalid #{path} with its complete configuration path" do
      expect { plan(config).definitions }.to raise_error(Empeira::ConfigurationError, /#{Regexp.escape(path)}/)
    end
  end

  ['https://example.com', '*', 'example.com;allow all', 'example.com\n', '127.0.0.1', '-x',
   'UPPER.example', '.example.org', 'example..org', '*.empeira.internal'].each do |domain|
    it "rejects unsafe allowlist input #{domain.inspect}" do
      expect do
        plan('proxy' => { 'global' => [domain] })
      end.to raise_error(Empeira::ConfigurationError, /proxy.global/)
    end
  end

  it 'renders exact domains and explicitly requested domain families with deny-by-default proxy rules' do
    config = plan('proxy' => { 'enabled' => true,
                               'global' => ['example.org', '*.example.net'] }).config['proxy']
    policy = Empeira::Network::ProxyPolicy.new(config).configuration +
             Empeira::Network::ProxyPolicy.domain_rules(config.fetch('global')).join("\n")
    expect(policy).to include('dstdomain -n example.org .example.net', 'http_access deny CONNECT !SSL_ports',
                              'acl Safe_ports port 80 443', 'http_access deny !Safe_ports',
                              'acl clients src "/empeira-proxy/proxy-clients"', 'http_access deny !clients',
                              'request_header_access Proxy-Authorization deny all')
    expect(Empeira::Network::ProxyPolicy.new(config).configuration.lines.last).to eq("http_access deny all\n")
    expect(policy).not_to include('ssl_bump', 'forbidden')
    Empeira::Network::ProxyPolicy::FORBIDDEN.split.each do |range|
      expect(policy).not_to include(range)
    end
  end

  it 'retains private IPv4, IPv6 and mapped-address restrictions exclusively for authenticated bootstrap' do
    policy = Empeira::Network::ProxyPolicy.new({ 'global' => ['example.test'] },
                                               authorization: 'synthetic-token').configuration
    expect(policy).to include("acl forbidden dst #{Empeira::Network::ProxyPolicy::FORBIDDEN}",
                              'http_access deny forbidden', 'http_access deny !clients',
                              'http_access deny !Safe_ports', 'http_access deny CONNECT !SSL_ports')
    ranges = Empeira::Network::ProxyPolicy::FORBIDDEN.split.map do |value|
      address, prefix = value.split('/')
      IPAddr.new("#{IPAddr.new(address).native}/#{prefix}")
    end
    %w[127.0.0.1 10.0.0.1 192.168.1.1 169.254.169.254 172.16.0.1 100.64.0.1].each do |address|
      [address, "::ffff:#{address}"].each do |form|
        expect(ranges.any? { |range| range.include?(IPAddr.new(form).native) }).to be(true)
      end
    end
    %w[:: ::1 fc00::1 fe80::1].each do |address|
      expect(ranges.any? { |range| range.include?(IPAddr.new(address)) }).to be(true)
    end
    expect(ranges.any? { |range| range.include?(IPAddr.new('::ffff:198.18.121.2').native) }).to be(false)
  end

  it 'adds proxy variables only to server traffic with complete internal bypass names' do
    definitions = plan('proxy' => { 'enabled' => true }).definitions
    env = definitions['server'].options['environment']
    expect(env['HTTPS_PROXY']).to eq('http://proxy.empeira.internal:3128')
    expect(env['NO_PROXY']).to include('server', 'puppetdb', 'postgres', '.empeira.internal', 'localhost')
    expect(definitions['postgres'].options['environment']).not_to have_key('HTTP_PROXY')
  end
end
