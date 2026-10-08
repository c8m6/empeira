# frozen_string_literal: true

require_relative 'support/runtime_execution'

RSpec.describe 'Container runtime network contracts' do
  shared_examples 'a network runtime' do |engine|
    let(:runner) { RuntimeExecution.new }
    let!(:app) { Empeira::Application.new(project_path: @directory, runner: runner) }
    let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: runner) }
    let(:definition) { Empeira::Infrastructure::Definition.new(context: app.context).network }

    it 'detects the engine without mutation and normalizes an absent network' do
      expect(runtime).to be_available
      expect(runtime.inspect_network(identifier: definition.backend_name)).to be_nil
      expect(runner.mutations).to be_empty
    end

    it 'selects the engine architecture from inspected runtime information' do
      info = runner.info(engine)
      info['Architecture'] = 'aarch64'
      allow(runner).to receive(:info).with(engine).and_return(info)
      expect(runtime.architecture).to eq('arm64')
      expect(runtime.architecture).to eq('arm64')
      expect(runner.calls.size).to eq(1)
    end

    it 'gates systemd mode on Podman cgroup v2 without a privileged fallback' do
      info = runner.info(engine)
      info['host'] ||= {}
      info['host']['cgroupVersion'] = 'v1'
      allow(runner).to receive(:info).with(engine).and_return(info)
      expect { runtime.require_systemd! }.to raise_error(Empeira::Runtime::UnsupportedCapability)
      info['host']['cgroupVersion'] = 'v2'
      runtime.check_available!
      if engine == 'podman'
        expect { runtime.require_systemd! }.not_to raise_error
      else
        expect { runtime.require_systemd! }.to raise_error(Empeira::Runtime::UnsupportedCapability)
      end
      expect(runner.mutations).to be_empty
    end

    it 'creates and inspects an owned isolated network and makes creation/removal idempotent' do
      result = runtime.create_network(definition: definition)
      expect(result.changed).to be(true)
      expect(result.resource).to have_attributes(isolated: true, labels: definition.labels, attachment_count: 0)
      expect(runtime.create_network(definition: definition).changed).to be(false)
      expect(runtime.inspect_network(identifier: result.resource.id)).to eq(result.resource)
      expect(runtime.remove_network(definition: definition, expected_id: result.resource.id).changed).to be(true)
      expect(runtime.remove_network(definition: definition).changed).to be(false)
      create = runner.mutations.first.last
      expect(create).to include('--internal', '--driver', 'bridge', '--label')
    end

    it 'fails closed on unverified isolation' do
      runner.isolation = false
      expect { runtime.create_network(definition: definition) }.to raise_error(Empeira::Network::UnsupportedPolicy)
      expect(runner.mutations.count).to eq(1)
    end

    it 'reports a missing/unexecutable CLI without exposing low-level exception details' do
      allow(runner).to receive(:run).and_raise(Empeira::ExecutionError, 'synthetic-secret')
      expect(runtime).not_to be_available
      expect { runtime.check_available! }.to raise_error(Empeira::Runtime::Unavailable) { |error|
        expect(error.full_message).not_to include('synthetic-secret')
        expect(error.message).to include(engine, 'Install', 'engine')
      }
    end

    it 'does not treat an engine failure as a missing network or leak captured output' do
      allow(runner).to receive(:run).and_return(
        Empeira::Execution::Result.new(stdout: 'synthetic-secret', stderr: 'synthetic-secret',
                                       exit_status: 125, timed_out: false)
      )
      expect { runtime.inspect_network(identifier: definition.backend_name) }
        .to raise_error(Empeira::Providers::ExecutionError) { |e| expect(e.full_message).not_to include('synthetic-secret') }
      expect { runtime.check_available! }.to raise_error(Empeira::Runtime::Unavailable)
    end

    it 'rejects malformed JSON without exposing output' do
      allow(runner).to receive(:run).and_return(
        Empeira::Execution::Result.new(stdout: '{synthetic-secret', stderr: '', exit_status: 0, timed_out: false)
      )
      expect { runtime.inspect_network(identifier: definition.backend_name) }
        .to raise_error(Empeira::Providers::ExecutionError) { |e| expect(e.full_message).not_to include('synthetic-secret') }
    end

    it 'reports a timed-out engine probe as unavailable' do
      allow(runner).to receive(:run).and_return(
        Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: nil, timed_out: true)
      )
      expect { runtime.check_available! }.to raise_error(Empeira::Runtime::Unavailable, /timed out/)
    end

    it 'rejects invalid structured inspection data before removal' do
      resource = runtime.create_network(definition: definition).resource
      runner.networks[engine][resource.id][engine == 'docker' ? 'Internal' : 'internal'] = 'true'
      expect { runtime.remove_network(definition: definition) }.to raise_error(Empeira::Providers::ExecutionError)
      expect(runner.mutations.count).to eq(1)
    end

    it 'does not infer absence when inspection fails after an inventory match' do
      runtime.create_network(definition: definition)
      allow(runner).to receive(:run).and_wrap_original do |method, executable, **options|
        if options[:arguments].take(2) == %w[network inspect]
          Empeira::Execution::Result.new(stdout: '', stderr: 'synthetic-secret', exit_status: 1, timed_out: false)
        else
          method.call(executable, **options)
        end
      end
      expect { runtime.remove_network(definition: definition) }.to raise_error(Empeira::Providers::ExecutionError)
      expect(runner.mutations.count).to eq(1)
    end

    it 'inspects an ambiguous removal and reports absence without blind retries' do
      runtime.create_network(definition: definition)
      allow(runner).to receive(:run).and_wrap_original do |method, executable, **options|
        result = method.call(executable, **options)
        raise Empeira::ExecutionError, 'synthetic launch outcome' if options[:arguments].take(2) == %w[network rm]

        result
      end
      expect { runtime.remove_network(definition: definition) }
        .to raise_error(Empeira::Providers::ExecutionError, /observed absent/)
      expect(runner.mutations.count).to eq(2)
      expect(runtime.remove_network(definition: definition).changed).to be(false)
    end

    it 'rejects unsupported runtime capabilities' do
      allow(runner).to receive(:info).and_return(engine == 'docker' ? { 'ServerVersion' => '27.0' } : { 'host' => {} })
      expect { runtime.check_available! }.to raise_error(Empeira::Runtime::UnsupportedCapability)
    end

    it 'inspects after a timeout without retrying creation' do
      runner.failure = :timeout
      expect { runtime.create_network(definition: definition) }
        .to raise_error(Empeira::Providers::ExecutionError, /observed present/)
      expect(runner.mutations.count).to eq(1)
      expect(runner.calls.map(&:last)).to include(%w[network inspect synthetic-1])
    end

    it 'inspects after an interrupt and preserves the interrupt' do
      runner.failure = :interrupt
      expect { runtime.create_network(definition: definition) }.to raise_error(Interrupt)
      expect(runner.mutations.count).to eq(1)
      expect(runner.calls.map(&:last)).to include(%w[network inspect synthetic-1])
    end

    it 'refuses destructive operations when the recorded ID differs' do
      runtime.create_network(definition: definition)
      expect { runtime.remove_network(definition: definition, expected_id: 'different-id') }
        .to raise_error(Empeira::Providers::OwnershipError)
      expect(runner.mutations.count).to eq(1)
    end

    it 'does not force removal of a network with attached resources' do
      result = runtime.create_network(definition: definition)
      if engine == 'docker'
        runner.networks[engine][result.resource.id]['Containers'] = { 'synthetic-container' => {} }
      else
        runner.attachments = 1
      end
      expect { runtime.remove_network(definition: definition) }
        .to raise_error(Empeira::Providers::ExecutionError, /attached/)
      expect(runner.mutations.count).to eq(1)
    end

    [nil, 'foreign-workspace', 'wrong-purpose'].each do |conflict|
      it "refuses to adopt/delete ownership conflict #{conflict.inspect}" do
        runtime.create_network(definition: definition)
        data = runner.networks[engine].values.first
        label_key = engine == 'docker' ? 'Labels' : 'labels'
        labels = data.fetch(label_key)
        labels.clear if conflict.nil?
        labels['io.empeira.workspace'] = conflict if conflict == 'foreign-workspace'
        labels['io.empeira.purpose'] = conflict if conflict == 'wrong-purpose'
        expect { runtime.create_network(definition: definition) }.to raise_error(Empeira::Providers::OwnershipError)
        expect { runtime.remove_network(definition: definition) }.to raise_error(Empeira::Providers::OwnershipError)
        expect(runner.mutations.count).to eq(1)
      end
    end
  end

  it_behaves_like 'a network runtime', 'docker'
  it_behaves_like 'a network runtime', 'podman'
end
