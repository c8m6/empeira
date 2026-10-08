# frozen_string_literal: true

require 'open3'

RSpec.describe Empeira::Node::Bootstrap do
  it 'defines only the logical provider fact for both node providers' do
    %w[container vm].each do |provider|
      files = described_class.new(provider: provider).files
      expect(files.size).to eq(1)
      expect(files.first.path).to eq(Empeira::Node::ExternalFact::PATH)
      expect(files.first.content).to eq("empeira:\n  provider: #{provider}\n")
      expect(files.first.mode).to eq(0o644)
    end
    expect { described_class.new(provider: 'docker') }.to raise_error(Empeira::ConfigurationError)
  end

  it 'installs and verifies the exact file through the container runtime' do
    path = File.join(@directory, 'facts.d', 'empeira.yaml')
    stub_const('Empeira::Node::ExternalFact::PATH', path)
    runtime = Object.new
    calls = []
    runtime.define_singleton_method(:service_exec) do |_resource, arguments|
      calls << arguments
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, *arguments.drop(1))
      Empeira::Execution::Result.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus,
                                     timed_out: false)
    end

    Empeira::Node::ContainerBootstrap.new(runtime: runtime)
                                     .apply(resource: {}, bootstrap: described_class.new(provider: 'container'))
    expect(calls.size).to eq(2)
    expect(YAML.safe_load_file(path)).to eq('empeira' => { 'provider' => 'container' })
    expect(File.stat(path).mode & 0o777).to eq(0o644)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o755)
  end

  it 'fails before Puppet when required state cannot be verified' do
    runtime = double('runtime')
    result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(result)
    expect do
      Empeira::Node::ContainerBootstrap.new(runtime: runtime)
                                       .apply(resource: {}, bootstrap: described_class.new(provider: 'container'))
    end
      .to raise_error(Empeira::Error, /Puppet was not run/)
  end

  it 'fails closed when installation succeeds but verification fails' do
    runtime = double('runtime')
    success = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    failure = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(success, failure)
    expect do
      Empeira::Node::ContainerBootstrap.new(runtime: runtime)
                                       .apply(resource: {}, bootstrap: described_class.new(provider: 'container'))
    end.to raise_error(Empeira::Error, /Cannot verify.*Puppet was not run/)
  end
end
