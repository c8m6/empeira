# frozen_string_literal: true

RSpec.shared_examples 'initial Puppet runs' do
  def sequence_provider(count = nil)
    @events = []
    progress = Empeira::Progress.new(listener: ->(event) { @events << event })
    provider = described_class.new(context: sequence_context(count), runner: app.runner, backend: sequence_backend,
                                   **(request.provider == 'vm' ? { runtime: runtime } : {}), progress: progress)
    observe_puppet_sequence(provider)
    [provider, progress]
  end

  def sequence_context(count)
    config = count ? { 'node_defaults' => { 'puppet_runs' => count } } : {}
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    app.context.with(configuration: Empeira::Configuration::Loader.new(project_path: @directory).load)
  end

  def sequence_backend
    return runtime if request.provider == 'container'

    instance_double(Empeira::VM::Qemu, preflight!: 'kvm', accelerator: 'kvm', image_tool: 'qemu-img')
  end

  def observe_puppet_sequence(provider)
    @puppet_calls = 0
    executor = request.provider == 'container' ? runtime : provider.instance_variable_get(:@guest)
    method = request.provider == 'container' ? :diagnostic_exec : :stream
    allow(executor).to receive(method) { next_puppet_result }
  end

  def next_puppet_result
    @puppet_calls += 1
    value = (@puppet_results || [0]).shift || 0
    raise value if value.is_a?(Exception)
    return value if value.is_a?(Empeira::Execution::Result)

    Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: value, timed_out: false)
  end

  def run_sequence(provider, progress)
    progress.run('Preparing node...') { provider.run(request) }
  end

  it 'runs once by default and records its final detailed exit code' do
    provider, progress = sequence_provider
    @puppet_results = [2]
    run_sequence(provider, progress)
    expect(@puppet_calls).to eq(1)
    expect(store.load.dig('nodes', request.hostname, 'last_puppet_exit')).to eq(2)
    expect(@events.map(&:message)).to include('Running Puppet agent (1/1)...')
  end

  [[0, 2, 0, 2], [4, 6, 2, 0]].each do |statuses|
    it "completes four sequential initial runs #{statuses.inspect} and preserves the last result" do
      provider, progress = sequence_provider(4)
      @puppet_results = statuses.dup
      run_sequence(provider, progress)
      expect(@puppet_calls).to eq(4)
      expect(store.load.dig('nodes', request.hostname)).to include('provisioned' => true,
                                                                   'last_puppet_exit' => statuses.last)
      expect(@events.map(&:message)).to include('Running Puppet agent (4/4)...',
                                                "Puppet run 4/4 finished with exit code #{statuses.last}.")
      provider.stop(name: request.hostname)
      provider.start(name: request.hostname)
      expect(@puppet_calls).to eq(4)
      expect(provider.puppet(name: request.hostname).exit_status).to eq(0)
      expect(@puppet_calls).to eq(request.provider == 'vm' ? 5 : 4)
      expect(store.load.dig('nodes', request.hostname, 'last_puppet_exit')).to eq(0)
    end
  end

  it 'retains a provisioned node when the last catalog fails and permits a later single run' do
    provider, progress = sequence_provider(4)
    @puppet_results = [0, 2, 0, 6]
    expect { run_sequence(provider, progress) }.to raise_error(Empeira::Error, /Puppet agent failed \(exit 6\)/)
    expect(@puppet_calls).to eq(4)
    expect(store.load.dig('nodes', request.hostname)).to include('provisioned' => true, 'last_puppet_exit' => 6)
    expect(provider.puppet(name: request.hostname).exit_status).to eq(0)
  end

  it 'aborts immediately when the confirmed guest transport fails' do
    provider, progress = sequence_provider(4)
    @puppet_results = [4, Empeira::Error.new('guest completion is unknown'), 0, 0]
    expect { run_sequence(provider, progress) }.to raise_error(Empeira::Error, /guest completion is unknown/)
    expect(@puppet_calls).to eq(2)
    expect(store.load.dig('nodes', request.hostname, 'last_puppet_exit')).to eq(4)
  end
end
