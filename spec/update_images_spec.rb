# frozen_string_literal: true

RSpec.describe 'Runtime image refresh' do
  %w[docker podman].each do |engine|
    context engine do
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:context) { Empeira::Application.new(project_path: @directory).context }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: context, runner: runner) }
      let(:success) { Empeira::Execution::Result.new(stdout: 'raw registry output', stderr: '', exit_status: 0, timed_out: false) }

      it 'pulls through the selected runtime without proxy or credential overrides' do
        allow(runner).to receive(:run).with(engine, arguments: ['image', 'inspect', 'registry.example/image:1'],
                                                    timeout: 30)
                                      .and_return(success.with(exit_status: 1))
        expect(runner).to receive(:run).with(engine, arguments: ['pull', 'registry.example/image:1'], timeout: 600)
                                       .and_return(success)
        expect { runtime.ensure_image('registry.example/image:1') }.not_to output.to_stdout
      end

      it 'refreshes reviewed builds in an isolated context and removes it afterward' do
        context_path = nil
        missing = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
        expect(runner).to receive(:run).with(engine, arguments: ['image', 'inspect', 'localhost/fixture:1'],
                                                     timeout: 30)
                                       .and_return(missing)
        expect(runner).to receive(:run) do |executable, arguments:, **|
          expect(executable).to eq(engine)
          expect(arguments.take(2)).to eq(['build', '--pull'])
          expect(arguments).not_to include('--no-cache')
          context_path = arguments.last
          expect(Dir.children(context_path).sort).to eq(%w[Containerfile resource.rb])
          expect(File.read(File.join(context_path, 'resource.rb'))).to eq('reviewed resource')
          success
        end
        runtime.refresh_image('localhost/fixture:1', recipe: 'FROM fixture:1',
                                                     files: { 'resource.rb' => 'reviewed resource' })
        expect(File.exist?(context_path)).to be(false)
      end

      it 'refuses to overwrite a foreign local build tag' do
        foreign = success.with(stdout: JSON.generate([{ 'Config' => { 'Labels' => {} } }]))
        expect(runner).to receive(:run).once.and_return(foreign)
        expect { runtime.refresh_image('localhost/fixture:1', recipe: 'FROM fixture:1') }
          .to raise_error(Empeira::Providers::OwnershipError, /recipe/)
      end

      it 'buffers registry failures and reports sanitized connectivity diagnostics' do
        stderr = "denied: https://user:secret@registry.example/private\nProxy-Authorization: Bearer secret\n"
        failure = Empeira::Execution::Result.new(stdout: '', stderr: stderr, exit_status: 1, timed_out: false)
        allow(runner).to receive(:run) do |_, arguments:, **|
          if [%w[manifest create], %w[manifest rm]].include?(arguments.take(2))
            success.with(stdout: 'c' * 64)
          else
            failure
          end
        end
        expect { runtime.refresh_image('registry.example/image:1') }.to raise_error(
          Empeira::Providers::ExecutionError
        ) do |error|
          expect(error.message).to include('remote image metadata failed', "#{engine} login registry.example")
          expect(error.message).not_to include('secret', 'Proxy-Authorization', 'allowlist', 'empeira status')
        end
      end
    end
  end
end

RSpec.describe 'Image build timeout cleanup' do
  it 'kills an actual hanging build process, retains diagnostics and deletes the isolated context' do
    runner = Empeira::Execution::Runner.new
    context = Empeira::Application.new(project_path: @directory).context
    runtime = Empeira::Runtime.registry.build('docker', context: context, runner: runner)
    directory = nil
    missing = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
    allow(runner).to receive(:run).and_wrap_original do |method, executable, arguments:, **options|
      if executable == 'docker' && arguments.first == 'image'
        missing
      else
        directory = arguments.last
        # A real Ruby child stands in for a stuck CLI build; all execution/timeout cleanup is real.
        code = 'STDOUT.sync = STDERR.sync = true; puts Process.pid; ' \
               'STDERR.puts "error: fixture build stalled"; sleep 30'
        result = method.call(RbConfig.ruby, arguments: ['-e', code], **options.merge(timeout: 2))
        expect(result.timed_out).to be(true)
        expect { Process.kill(0, Integer(result.stdout.strip)) }.to raise_error(Errno::ESRCH)
        result
      end
    end
    expect do
      runtime.refresh_image('localhost/fixture:timeout', recipe: 'FROM fixture:1')
    end.to raise_error(Empeira::Providers::ExecutionError, /timeout.*fixture build stalled/m)
    expect(File.exist?(directory)).to be(false)
  end
end
