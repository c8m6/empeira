# frozen_string_literal: true

require_relative 'support/memory_backend'

RSpec.describe 'Provider contracts' do
  let(:application) { Empeira::Application.new(project_path: @directory) }
  let(:request) do
    Empeira::Node::RunRequest.from_config(hostname: 'host1', provider: 'container',
                                          config: application.context.configuration)
  end

  def run_resource
    if adapter.is_a?(Empeira::Node::Interface)
      adapter.run(request)
    else
      adapter.run(name: request.hostname, request: request)
    end
  end

  shared_examples 'an owned lifecycle' do |interface|
    let(:adapter) do
      options = { name: 'test', context: application.context, runner: application.runner }
      options[:backend] = Object.new if interface == Empeira::Node::Interface
      Class.new(interface) { include MemoryBackend }.new(**options)
    end

    it 'identifies itself and reports availability without changing state' do
      expect(adapter.name).to eq('test')
      expect(adapter).to be_available
      expect(adapter.inspect_resource(name: 'host1')).to be_nil
    end

    it 'creates a running owned resource and rejects duplicate creation' do
      result = run_resource
      expect(result).to be_frozen
      expect(result.changed).to be(true)
      expect(result.resource).to have_attributes(name: 'host1', owner: application.context.workspace.id,
                                                 state: :running)
      expect { run_resource }.to raise_error(Empeira::Providers::AlreadyExists)
    end

    it 'makes repeated start and stop operations idempotent while preserving identity' do
      original = run_resource.resource
      expect(adapter.start(name: 'host1').changed).to be(false)
      stopped = adapter.stop(name: 'host1')
      expect(stopped.changed).to be(true)
      expect(stopped.resource).to eq(original.with(state: :stopped))
      expect(adapter.stop(name: 'host1').changed).to be(false)
      expect(adapter.start(name: 'host1').resource).to eq(original)
    end

    it 'returns not found for missing start/stop and makes destroy idempotent' do
      expect { adapter.start(name: 'missing') }.to raise_error(Empeira::Providers::NotFound)
      expect { adapter.stop(name: 'missing') }.to raise_error(Empeira::Providers::NotFound)
      expect(adapter.destroy(name: 'missing').changed).to be(false)
      run_resource
      expect(adapter.destroy(name: 'host1')).to eq(Empeira::Providers::Result.new(resource: nil, changed: true))
      expect(adapter.destroy(name: 'host1').changed).to be(false)
    end

    it 'refuses to inspect or mutate a resource owned by another workspace' do
      adapter.records['host1'] =
        Empeira::Providers::Resource.new(name: 'host1', owner: 'another-workspace', state: :running)
      %i[inspect_resource start stop destroy].each do |operation|
        expect { adapter.public_send(operation, name: 'host1') }.to raise_error(Empeira::Providers::OwnershipError)
      end
      expect { run_resource }.to raise_error(Empeira::Providers::OwnershipError)
      expect(adapter.records.size).to eq(1)
    end

    it 'does not convert provider execution failures into successful results' do
      run_resource
      allow(adapter).to receive(:transition).and_raise(Empeira::Providers::ExecutionError, 'Operation failed')
      expect { adapter.stop(name: 'host1') }.to raise_error(Empeira::Providers::ExecutionError)
      expect(adapter.inspect_resource(name: 'host1').state).to eq(:running)
    end

    it 'rejects a false lookup result instead of treating an unknown outcome as absence' do
      allow(adapter).to receive(:lookup).and_return(false)
      expect { adapter.inspect_resource(name: 'host1') }.to raise_error(Empeira::Providers::ExecutionError)
    end

    it 'rejects malformed adapter responses' do
      allow(adapter).to receive(:create).and_return(nil)
      expect { run_resource }.to raise_error(Empeira::Providers::ExecutionError)
    end
  end

  it_behaves_like 'an owned lifecycle', Empeira::Runtime::Interface
  it_behaves_like 'an owned lifecycle', Empeira::Node::Interface
  it_behaves_like 'an owned lifecycle', Empeira::VM::Interface

  it 'keeps container execution unavailable while network adapters exist' do
    Empeira::Runtime.registry.names.each do |name|
      runtime = Empeira::Runtime.registry.build(name, context: application.context, runner: application.runner)
      expect(runtime.name).to eq(name)
      expect { runtime.run(name: 'host1', request: request) }.to raise_error(Empeira::UnavailableFeature)
    end
  end

  it 'keeps VM engines and images behind separate lazy catalogs' do
    expect(Empeira::VM.registry.names).to eq(['qemu'])
    expect(Empeira::Node.registry.names).to eq(%w[container vm])
    Empeira::Images.registry.names.each do |name|
      expect { Empeira::Images.registry.build(name).fetch(identity: :synthetic) }.to raise_error(Empeira::UnavailableFeature)
    end
  end

  it 'rejects unknown selections without constructing anything' do
    expect { Empeira::Node.registry.build('qemu') }.to raise_error(Empeira::Error, /container, vm/)
  end
end
