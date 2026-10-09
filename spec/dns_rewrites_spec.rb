# frozen_string_literal: true

RSpec.describe 'DNS rewrite configuration and discovery' do
  def context(rewrites = [], **config)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config.merge('dns' => { 'rewrites' => rewrites })))
    Empeira::Application.new(project_path: @directory).context
  end

  def rewrite(source = 'ipam.example.net', target = 'api-layer.empeira.internal')
    { 'from' => source, 'to' => target }
  end

  it 'defaults to no rewrites and replaces arrays through the existing loader' do
    expect(context.configuration.dig('dns', 'rewrites')).to eq([])
    expect(context([rewrite]).configuration.dig('dns', 'rewrites')).to eq([rewrite])
  end

  it 'normalizes case and the trailing root dot and allows shared targets' do
    current = context([rewrite('IPAM.Example.Net.', 'API-LAYER.Empeira.Internal.'),
                       rewrite('inventory.example.net')])
    expect(Empeira::Configuration::DNSRewrites.entries(current.configuration))
      .to eq([rewrite('inventory.example.net'), rewrite])
  end

  it 'rejects duplicate sources after DNS normalization' do
    expect { context([rewrite, rewrite('IPAM.EXAMPLE.NET.')]) }
      .to raise_error(Empeira::ConfigurationError, /dns.rewrites\[1\].from.*duplicates/)
  end

  [nil, {}, 'ipam.example.net', [nil], [{ 'from' => 'ipam.example.net' }],
   [{ 'from' => 'ipam.example.net', 'to' => 'api-layer.empeira.internal', 'extra' => true }],
   [{ 'from' => 'ipam.example.net', 1 => 'api-layer.empeira.internal' }]].each do |value|
    it "rejects malformed rewrite entries #{value.inspect}" do
      expect { context(value) }.to raise_error(Empeira::ConfigurationError, /dns.rewrites/)
    end
  end

  ['*.example.net', 'api?.example.net', 'https://ipam.example.net', 'ipam.example.net:53',
   '-ipam.example.net', 'ipam..example.net', '192.0.2.1', '2001:db8::1',
   "ipam.example.net\nreload", "#{'a' * 64}.example.net", (['a' * 63] * 4).join('.')].each do |name|
    it "rejects an invalid source #{name.inspect}" do
      expect { context([rewrite(name)]) }.to raise_error(Empeira::ConfigurationError, /dns.rewrites\[0\].from/)
    end
  end

  ['api.example.net', 'empeira.internal', 'nested.api.empeira.internal', '192.0.2.1',
   '*.empeira.internal', 'api_layer.empeira.internal'].each do |target|
    it "rejects invalid or non-service targets #{target.inspect}" do
      expect { context([rewrite('ipam.example.net', target)]) }
        .to raise_error(Empeira::ConfigurationError, /dns.rewrites\[0\].to/)
    end
  end

  %w[empeira.internal EMPEIRA.INTERNAL. api-layer.empeira.internal deep.api.empeira.internal].each do |source|
    it "protects the internal zone from #{source}" do
      expect { context([rewrite(source)]) }.to raise_error(Empeira::ConfigurationError, /outside empeira.internal/)
    end
  end

  it 'rejects self references and cycles by keeping all sources outside the target zone' do
    expect { context([rewrite('api-layer.empeira.internal')]) }.to raise_error(Empeira::ConfigurationError)
    expect do
      context([rewrite('first.empeira.internal', 'second.empeira.internal'),
               rewrite('second.empeira.internal', 'first.empeira.internal')])
    end.to raise_error(Empeira::ConfigurationError)
  end

  it 'uses authoritative discovery for exact rewrites and retains forwarding for unmatched descendants' do
    files = Empeira::ControlPlane::Files.new(context: context([rewrite]))
    files.prepare(upstreams: ['192.0.2.53'], routes: { 'example.net' => ['192.0.2.54'] })
    generated = File.read(files.path('Corefile')).split('ipam.example.net:53').last
    expect(generated).to include('rewrite stop name exact ipam.example.net api-layer.empeira.internal',
                                 'hosts /empeira/hosts empeira.internal', 'forward . 192.0.2.54')
    expect(generated).not_to include('fallthrough')
    expect(generated).to include('except empeira.internal')
    expect(files.configuration.fetch('Corefile')).not_to include('ipam.example.net')
  end

  it 'keeps the DNS container fingerprint and all network/proxy definitions independent of rewrites' do
    before = Empeira::ControlPlane::Plan.new(context: context).fingerprints
    after = Empeira::ControlPlane::Plan.new(context: context([rewrite])).fingerprints
    expect(after).to eq(before)
  end

  it 'retains a split-DNS route when its zone equals an exact rewrite source' do
    files = Empeira::ControlPlane::Files.new(context: context([rewrite]))
    files.prepare(upstreams: ['192.0.2.53'], routes: { 'ipam.example.net' => ['192.0.2.54'] })
    generated = File.read(files.path('Corefile'))
    expect(generated.scan('ipam.example.net:53').size).to eq(1)
    expect(generated.split('ipam.example.net:53').last).to include('forward . 192.0.2.54')
  end

  it 'reports targets absent from the enabled service plan, including node identities' do
    plan = Empeira::ControlPlane::Plan.new(context: context([rewrite]))
    expect do
      plan.validate_dns_rewrites!
    end.to raise_error(Empeira::ConfigurationError, /target service.*missing or disabled/)
    plan = Empeira::ControlPlane::Plan.new(context: context([rewrite('db.example.net', 'postgres.empeira.internal')],
                                                            'puppetdb' => { 'enabled' => false }))
    expect { plan.validate_dns_rewrites! }.to raise_error(Empeira::ConfigurationError, /postgres.empeira.internal/)
  end
end
