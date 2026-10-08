# frozen_string_literal: true

RSpec.describe 'Additional DNS resolver configuration' do
  def files(config = {})
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    context = Empeira::Application.new(project_path: @directory).context
    Empeira::ControlPlane::Files.new(context: context)
  end

  it 'preserves the existing Corefile when no additional resolver is configured' do
    generated = files
    corefile = generated.configuration.fetch('Corefile')
    expect(corefile).to include("  forward . @HOST_UPSTREAM@\n  loop\n")
    expect(corefile.scan('forward .').size).to eq(1)
    expect(corefile).not_to include('next NXDOMAIN', 'next_on_nodata')
    generated.prepare(upstreams: ['10.20.30.1'], routes: { 'corp.test' => ['10.20.30.2'] })
    expect(File.read(generated.path('Corefile')))
      .to include("corp.test:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  forward . 10.20.30.2\n  loop\n")
  end

  it 'forwards external names to the additional resolver before the host upstream' do
    generated = files('dns' => { 'additional_resolver' => 'resolver.example.test' })
    generated.prepare(upstreams: ['10.20.30.1'], routes: { 'corp.test' => ['10.20.30.2'] })
    corefile = File.read(generated.path('Corefile'))
    expect(corefile).to include(forwarder_lines('resolver.example.test', '10.20.30.1'))
    expect(corefile).to include("corp.test:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  #{forwarder_lines(
      'resolver.example.test', '10.20.30.2'
    )}")
    expect(corefile)
      .to start_with("empeira.internal:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  hosts /empeira/hosts {\n")
    expect(corefile.split('.:53 {').first).not_to include('forward')
  end

  it 'uses only the existing upstream until the additional resolver is activated' do
    generated = files('dns' => { 'additional_resolver' => 'resolver.example.test' })
    inputs = { upstreams: ['10.20.30.1'], routes: { 'corp.test' => ['10.20.30.2'] } }

    generated.prepare(**inputs, bootstrap: true)
    bootstrap = File.read(generated.path('Corefile'))
    expect(bootstrap).to include("  forward . 10.20.30.1\n  loop\n  reload\n")
    expect(bootstrap)
      .to include("corp.test:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  forward . 10.20.30.2\n  " \
                  "loop\n  reload\n")
    expect(bootstrap).not_to include('resolver.example.test')
    expect(generated.corefile_current?(**inputs)).to be(false)

    generated.activate_additional_resolver(**inputs)
    active = File.read(generated.path('Corefile'))
    expect(active).to include(forwarder_lines('resolver.example.test', '10.20.30.1'))
    expect(active).to include("corp.test:53 {\n  template IN AAAA {\n    rcode NOERROR\n  }\n  #{forwarder_lines(
      'resolver.example.test', '10.20.30.2'
    )}")
    expect(generated.corefile_current?(**inputs)).to be(true)
  end

  it 'keeps explicit upstream servers behind an IP additional resolver' do
    generated = files('dns' => { 'additional_resolver' => '10.20.30.53',
                                 'upstream' => { 'mode' => 'explicit', 'servers' => %w[10.20.30.1 10.20.30.2] } })
    corefile = generated.configuration.fetch('Corefile')
    expect(corefile).to include(forwarder_lines('10.20.30.53', '10.20.30.1 10.20.30.2'))
    expect(corefile).not_to include('@HOST_UPSTREAM@')
  end

  it 'accepts DNS names and IPs without requiring a service or checking reachability' do
    %w[resolver.example.test Resolver.Example.Test infoblox.empeira.internal
       10.20.30.53].each do |resolver|
      expect { files('dns' => { 'additional_resolver' => resolver }) }.not_to raise_error
    end
  end

  ['https://resolver.test', 'resolver.test:53', "resolver.test\nforward . 1.1.1.1",
   '*.example.test', '999.999.999.999'].each do |resolver|
    it "rejects invalid resolver syntax #{resolver.inspect}" do
      expect { files('dns' => { 'additional_resolver' => resolver }) }
        .to raise_error(Empeira::ConfigurationError, /dns.additional_resolver/)
    end
  end

  def forwarder_lines(additional, upstream)
    "forward . #{additional} {\n    next NXDOMAIN\n    next_on_nodata\n  }\n  forward . #{upstream}"
  end
end
