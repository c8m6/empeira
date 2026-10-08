# frozen_string_literal: true

require 'empeira/cli/main'

RSpec.describe Empeira::Application do
  around { |example| Dir.chdir(@directory) { example.run } }

  it 'delivers the canonical workspace, effective runtime, runner and platform to only the selected factory' do
    root2 = File.join(@directory, 'other')
    initialize_project(root2)
    contexts = []
    %w[podman docker].zip([@directory, root2]).each do |runtime_name, project|
      selected = instance_double(Empeira::Runtime::Container, check_available!: true)
      factories = Empeira::Providers::Registry.new(runtime_name => lambda { |context:, runner:|
        expect(context.container_engine).to eq(runtime_name)
        expect(context.project.path).to eq(Pathname(project).realpath)
        expect(context.workspace.path).to eq(context.project.path)
        expect(runner).to be_a(Empeira::Execution::Runner)
        contexts << context
        selected
      })
      application = described_class.new(project_path: project,
                                        overrides: { 'runtime' => { 'container_engine' => runtime_name } },
                                        factories: { runtimes: factories })
      expect(Empeira::Node::Container).to receive(:new).with(
        context: application.context,
        runner: application.runner, backend: selected, build_info: anything, progress: anything
      ).and_call_original
      expect do
        application.run_node(hostname: 'host1', provider: 'container')
      end.to raise_error(Empeira::Error, /empeira up first/)
    end
    expect(contexts.map { |context| context.workspace.id }.uniq.size).to eq(2)
    expect(Empeira::Node::RunRequest.members).not_to include(:runtime, :container_engine, :docker, :podman)
  end

  it 'preserves context and runtime selection through the actual Thor command handoff' do
    expect(Empeira::Runtime::Docker).to receive(:new) do |context:, runner:|
      expect(context.workspace.path).to eq(Pathname(@directory).realpath)
      expect(context.configuration['runtime']['container_engine']).to eq('docker')
      expect(runner).to be_a(Empeira::Execution::Runner)
      instance_double(Empeira::Runtime::Container, check_available!: true)
    end
    expect do
      Empeira::CLI::Main.start(['node', 'run', 'host1', '--provider', 'container',
                                '--container-engine', 'docker'])
    end.to raise_error(Empeira::Error, /empeira up first/)
  end

  it 'constructs QEMU and the selected runtime for the isolated VM service gateway' do
    expect(Empeira::Runtime::Podman).to receive(:new).with(context: anything, runner: anything).and_call_original
    expect(Empeira::VM::Qemu).to receive(:new).with(context: anything,
                                                    runner: anything).and_call_original
    expect { described_class.new(project_path: @directory).run_node(hostname: 'host1', provider: 'vm') }
      .to raise_error(Empeira::Error, /empeira up first/)
  end

  it 'does not construct providers for metadata, help, configuration or completion' do
    [Empeira::Runtime::Interface, Empeira::Node::Interface, Empeira::VM::Interface,
     Empeira::Images::Source].each do |implementation|
      expect(implementation).not_to receive(:new)
    end
    expect(Empeira::Runtime.registry.names).to eq(%w[podman docker])
    expect { Empeira::Runtime.registry.names << 'another' }.to raise_error(FrozenError)
    [%w[help], %w[config validate], %w[completion bash]].each do |command|
      expect { Empeira::CLI::Main.start(command + []) }.to output.to_stdout
    end
  end

  it 'protects effective configuration in the shared context from mutation' do
    application = described_class.new(project_path: @directory)
    expect { application.context.configuration['node_defaults']['memory'] = 1 }.to raise_error(FrozenError)
  end
end
