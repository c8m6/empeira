# frozen_string_literal: true

require_relative 'support/service_runtime'

RSpec.describe Empeira::ControlPlane::DNSConfiguration do
  let(:runtime) { ServiceRuntime.new }
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: context) }
  let(:files) { plan.files }
  let(:inventory) { { 'services' => {} } }
  let(:persisted) { [] }
  let(:configuration) do
    described_class.new(plan: plan, runtime: runtime, inventory: inventory,
                        persist: -> { persisted << Marshal.load(Marshal.dump(inventory)) })
  end
  let(:inputs) { { upstreams: ['192.0.2.53'], routes: {} } }

  before do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('server' => { 'timeout' => 1 }))
    files.prepare(**inputs)
    @old = File.binread(files.path('Corefile'))
    @new = files.corefile_content(**inputs, upstreams: ['192.0.2.54'])
    @active = { 'dns' => @old }
    %w[dns server].each do |key|
      definition = plan.definitions.fetch(key)
      resource = runtime.create_service(definition)
      runtime.start_service(resource)
      inventory['services'][key] = { 'id' => resource.fetch('id') }
    end
    allow(runtime).to receive(:start_service).and_wrap_original do |method, resource|
      method.call(resource)
      @active['dns-validation'] = File.binread(files.path('Corefile.next')) if
        resource.equal?(runtime.services['dns-validation'])
    end
    allow(runtime).to receive(:reload_service).and_wrap_original do |method, resource, **options|
      method.call(resource, **options)
      @active['dns'] = File.binread(files.path('Corefile')) unless @ignore_reload
    end
    allow(runtime).to receive(:service_exec).and_wrap_original do |method, resource, arguments, **options|
      result = method.call(resource, arguments, **options)
      next result unless arguments[2] == described_class::PROBE

      target = runtime.services.find do |_, service|
        service.dig('networks', plan.network, 'IPAddress') == arguments[-2]
      end&.first
      expected = @active[target]&.include?(arguments.last)
      result.with(exit_status: expected ? 0 : 1)
    end
  end

  def activate
    configuration.activate(@new, resources: runtime.services.slice('dns', 'server'))
  end

  it 'validates before publishing, verifies the served generation and stays idle on unchanged up' do
    id = runtime.services.fetch('dns').fetch('id')
    expect(activate).to be(true)
    expect(File.binread(files.path('Corefile'))).to eq(@new)
    expect(File.binread(files.path('Corefile.last-good'))).to eq(@new)
    expect(@active.fetch('dns')).to eq(@new)
    expect(runtime.services.keys).to match_array(%w[dns server])
    expect(inventory['services']).not_to have_key('dns-validation')
    expect(persisted).to include(hash_including('services' => hash_including('dns-validation' => { 'id' => nil })))
    expect(runtime.services.fetch('dns').fetch('id')).to eq(id)
    calls = runtime.calls.dup
    expect(activate).to be(false)
    expect(runtime.calls.drop(calls.size).map(&:first)).to eq([:exec])
  end

  it 'preserves the working file and reports native diagnostics when the candidate cannot start' do
    allow(runtime).to receive(:start_service).and_wrap_original do |method, resource|
      method.call(resource)
      resource['state'] = 'exited' if resource.equal?(runtime.services['dns-validation'])
    end
    allow(runtime).to receive(:service_logs).and_return('plugin/forward: failed to resolve fixture.invalid')
    expect { activate }.to raise_error(Empeira::Error, /candidate validation failed.*\n.*failed to resolve/m)
    expect(File.binread(files.path('Corefile'))).to eq(@old)
    expect(@active.fetch('dns')).to eq(@old)
    expect(runtime.calls.none? { |call| call.first == :reload }).to be(true)
    expect(runtime.services.keys).to match_array(%w[dns server])
  end

  it 'detects a rejected reload despite a successful signal and restores the served previous configuration' do
    @ignore_reload = true
    expect { activate }.to raise_error(Empeira::Error, /activation failed; previous Corefile restored/)
    expect(File.binread(files.path('Corefile'))).to eq(@old)
    expect(@active.fetch('dns')).to eq(@old)
    expect(runtime.calls.count { |call| call.first == :reload }).to eq(2)
    @ignore_reload = false
    expect(activate).to be(true)
    expect(@active.fetch('dns')).to eq(@new)
  end

  it 'retries activation when desired bytes exist on disk but the live server still serves the old generation' do
    File.binwrite(files.path('Corefile.last-good'), @old)
    File.binwrite(files.path('Corefile'), @new)
    expect(activate).to be(true)
    expect(@active.fetch('dns')).to eq(@new)
  end

  it 'cleans up a helper with an uncertain creation outcome using its recorded intent and ownership' do
    runtime.failure = 'dns-validation'
    expect { activate }.to raise_error(Empeira::Error, /uncertain creation/)
    expect(runtime.services.keys).to match_array(%w[dns server])
    expect(inventory['services']).not_to have_key('dns-validation')
    expect(File.binread(files.path('Corefile'))).to eq(@old)
  end

  it 'reports unverifiable legacy restoration explicitly after restoring the file and signalling CoreDNS' do
    legacy = @old.split('_empeira-config.empeira.internal:53').first
    File.binwrite(files.path('Corefile'), legacy)
    @active['dns'] = legacy
    @ignore_reload = true
    expect { activate }.to raise_error(Empeira::Error, /restored on disk, but reactivation could not be verified/)
    expect(File.binread(files.path('Corefile'))).to eq(legacy)
    expect(runtime.calls.count { |call| call.first == :reload }).to eq(2)
  end
end
