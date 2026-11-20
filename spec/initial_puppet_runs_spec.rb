# frozen_string_literal: true

require_relative '../lib/empeira/node/initial_puppet_runs'

RSpec.describe Empeira::Node::InitialPuppetRuns do
  let(:events) { [] }
  let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }

  it 'defaults to one and accepts the configured integer range' do
    expect(Empeira::Configuration::Loader.new(project_path: @directory).load.dig('node_defaults',
                                                                                 'puppet_runs')).to eq(1)
    [1, 4, 10].each do |value|
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('node_defaults' => { 'puppet_runs' => value }))
      expect(Empeira::Application.new(project_path: @directory).context.configuration.dig('node_defaults',
                                                                                          'puppet_runs'))
        .to eq(value)
    end
  end

  [nil, false, true, 0, -1, 11, '4', 4.0, [], {}].each do |value|
    it "rejects puppet_runs #{value.inspect} with its configuration path" do
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('node_defaults' => { 'puppet_runs' => value }))
      expect { Empeira::Application.new(project_path: @directory) }
        .to raise_error(Empeira::ConfigurationError, /node_defaults.puppet_runs must be an integer between 1 and 10/)
    end
  end

  def result(status, timed_out: false)
    Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: status, timed_out: timed_out)
  end

  def sequence(statuses)
    count = statuses.size
    progress.run('Preparing node...') do
      described_class.new(count: count, progress: progress).run { result(statuses.shift) }
    end
  end

  it 'continues after completed failures and lets the final successful run decide' do
    expect(sequence([4, 6, 2, 0]).exit_status).to eq(0)
    expect(events.select { |event| event.state == :warning }.map(&:message))
      .to eq(['Puppet run 1/4 finished with exit code 4.', 'Puppet run 2/4 finished with exit code 6.'])
    expect(events.map(&:message)).to include('Running Puppet agent (1/4)...', 'Running Puppet agent (4/4)...',
                                             'Puppet run 4/4 finished with exit code 0.',
                                             'Node provisioning completed successfully.')
  end

  it 'accepts changes in the final run and rejects a failing final run' do
    expect(sequence([1, 4, 0, 2]).exit_status).to eq(2)
    expect { sequence([0, 2, 0, 6]) }.to raise_error(Empeira::Error, /Puppet agent failed \(exit 6\)/)
  end

  it 'does not retry transport exceptions, interruptions, timeouts or an unstartable process' do
    [Empeira::VM::Guest::TransportError.new('lost connection'), Empeira::ExecutionError.new('runtime unavailable'),
     Interrupt.new].each do |error|
      calls = 0
      expect do
        described_class.new(count: 4, progress: progress).run do
          calls += 1
          raise error
        end
      end.to raise_error(error.class)
      expect(calls).to eq(1)
    end
    [result(nil, timed_out: true), result(124, timed_out: true), result(126), result(127),
     result(143)].each do |failure|
      calls = 0
      expect do
        described_class.new(count: 4, progress: progress).run do
          calls += 1
          failure
        end
      end.to raise_error(Empeira::Error, /did not complete normally/)
      expect(calls).to eq(1)
    end
  end
end
