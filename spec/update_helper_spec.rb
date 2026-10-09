# frozen_string_literal: true

RSpec.describe Empeira::Runtime::UpdateHelper do
  %w[docker podman].each do |engine|
    context engine do
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:context) { Empeira::Application.new(project_path: @directory).context }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: context, runner: runner) }
      let(:calls) { [] }
      let(:output) { File.join(@directory, 'output') }
      let(:input) { File.join(@directory, 'input') }
      let(:sources) { File.join(@directory, 'sources') }
      let(:cache) { File.join(@directory, 'cache') }

      before do
        FileUtils.mkdir_p([output, input, sources, cache])
        %w[Puppetfile request.json].each { |file| File.write(File.join(input, file), '') }
        @resource = nil
        allow(runner).to receive(:run) do |_, arguments:, **|
          calls << arguments
          @created = true if arguments.first == 'create'
          @created = false if arguments.first == 'rm'
          Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
        end
        allow(runtime).to receive(:inspect_service) do |identity, expected_id: nil|
          if @created
            @resource ||= { 'id' => 'owned-helper', 'name' => identity.name, 'labels' => identity.labels,
                            'networks' => { engine == 'docker' ? 'bridge' : 'podman' => {} },
                            'dns' => [], 'ports' => {}, 'published_ports' => {} }
            identity.verify!(@resource, expected_id: expected_id)
            @resource
          end
        end
      end

      def run_helper(&)
        runtime.with_update_helper(image: 'fixture:1', input: input, output: output, sources: sources, cache: cache, &)
      end

      it 'uses only normal runtime networking, readonly inputs and a persistent output mount' do
        run_helper { expect(@created).to be(true) }
        create = calls.first
        expect(create.each_cons(2).to_a).to include(['--network', engine == 'docker' ? 'bridge' : 'podman'])
        expect(create.join(' ')).not_to include('--dns', '--hostname', '.empeira.internal', 'SSH_AUTH_SOCK', '.ssh')
        expect(create).to include("type=bind,src=#{File.realpath(input)}/Puppetfile,dst=/work/Puppetfile,readonly")
        expect(create).to include("type=bind,src=#{File.realpath(output)},dst=/work/modules")
        expect(calls.last).to eq(['rm', '--force', '--volumes', 'owned-helper'])
        expect(@created).to be(false)
        expect(File.directory?(output)).to be(true)
      end

      it 'inherits only supplied user proxy variables without putting credentials in arguments' do
        previous = ENV.to_h
        ENV['HTTPS_PROXY'] = 'http://user:secret@proxy.example:3128'
        ENV['SSH_AUTH_SOCK'] = '/existing/user/agent.sock'
        run_helper { nil }
        expect(calls.first.each_cons(2).to_a).to include(['--env', 'HTTPS_PROXY'])
        expect(calls.flatten.join(' ')).not_to include('secret', 'proxy.empeira.internal', 'agent.sock')
      ensure
        ENV.replace(previous)
      end

      it 'removes the owned helper on failure and interruption' do
        [Empeira::Error, Interrupt].each do |error|
          @resource = nil
          expect { run_helper { raise error, 'fixture failure' } }.to raise_error(error, /fixture failure/)
          expect(@created).to be(false)
        end
      end

      it 'rejects workspace membership before synchronization and removes the owned helper' do
        allow(runtime).to receive(:verify_helper_network!).and_wrap_original do |method, *args|
          @resource['networks'] = { "empeira-#{context.workspace.id}-network" => {} }
          method.call(*args)
        end
        expect { run_helper { raise 'must not run' } }.to raise_error(Empeira::Providers::OwnershipError, /network/)
        expect(@created).to be(false)
      end

      it 'recovers and removes an owned creation after a failed create response' do
        allow(runtime).to receive(:update_command).and_wrap_original do |method, arguments, **options|
          result = method.call(arguments, **options)
          raise Empeira::Providers::ExecutionError, 'creation response lost' if arguments.first == 'create'

          result
        end
        expect { run_helper { nil } }.to raise_error(Empeira::Providers::ExecutionError, /response lost/)
        expect(@created).to be(false)
      end

      it 'runs native agent tooling in an owned helper without host bind mounts or isolated workspace access' do
        runtime.with_agent_helper(image: 'synthetic-agent-tooling:1') do |resource|
          expect(resource.fetch('id')).to eq('owned-helper')
        end
        create = calls.first
        expect(create.each_cons(2).to_a).to include(['--network', engine == 'docker' ? 'bridge' : 'podman'])
        expect(create).not_to include('--mount', '--volume', '--privileged', '--publish', '--dns')
        expect(calls.last).to eq(['rm', '--force', '--volumes', 'owned-helper'])
        expect(@created).to be(false)
      end

      it 'verifies agent-helper networking before acquisition and cleans after a lost creation response' do
        allow(runtime).to receive(:verify_helper_network!).and_wrap_original do |method, *args|
          @resource['networks'] = { "empeira-#{context.workspace.id}-network" => {} }
          method.call(*args)
        end
        expect { runtime.with_agent_helper(image: 'fixture:1') { raise 'must not acquire' } }
          .to raise_error(Empeira::Providers::OwnershipError, /network/)
        expect(@created).to be(false)
        @resource = nil
        allow(runtime).to receive(:update_command).and_wrap_original do |method, arguments, **options|
          result = method.call(arguments, **options)
          raise Empeira::Providers::ExecutionError, 'creation response lost' if arguments.first == 'create'

          result
        end
        expect { runtime.with_agent_helper(image: 'fixture:1') { nil } }
          .to raise_error(Empeira::Providers::ExecutionError, /response lost/)
        expect(@created).to be(false)
      end

      it 'cleans agent helpers after acquisition failure or interruption' do
        [Empeira::Error, Interrupt].each do |error|
          @resource = nil
          expect { runtime.with_agent_helper(image: 'fixture:1') { raise error, 'download interrupted' } }
            .to raise_error(error, /download interrupted/)
          expect(@created).to be(false)
        end
      end

      it 'retains network guidance for other image build failures' do
        allow(runner).to receive(:run).and_return(
          Empeira::Execution::Result.new(stdout: '', stderr: 'connection refused',
                                         exit_status: 1, timed_out: false)
        )

        expect { runtime.update_command(['build'], operation: 'managed image build') }
          .to raise_error(Empeira::Providers::ExecutionError, /network access/)
      end
    end
  end
end
