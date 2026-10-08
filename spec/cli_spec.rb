# frozen_string_literal: true

require 'empeira/cli/main'
require_relative 'support/runtime_execution'

RSpec.describe Empeira::CLI::Main do
  around { |example| Dir.chdir(@directory) { example.run } }

  def cli(*args)
    preload = File.expand_path('support/isolated_cli_locations.rb', __dir__)
    Empeira::Execution::Runner.new.run(RbConfig.ruby,
                                       arguments: ['-r', preload, File.expand_path('../bin/empeira', __dir__), *args],
                                       environment: { 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') },
                                       directory: @directory, timeout: 15)
  end

  it 'reports development version and help' do
    expect(cli('--version').stdout).to eq("Empeira development\n")
    result = cli('help')
    expect(result).to be_success
    expect(result.stdout).to include('config', 'status', 'node', 'images', 'update', 'browser', 'completion')
  end

  it 'loads host preferences in the real CLI and lets an explicit runtime override win' do
    File.write(File.join(@directory, 'user-home', '.empeira.yaml'), 'runtime: {container_engine: docker}')
    expect(YAML.safe_load(cli('config', 'show').stdout).dig('runtime', 'container_engine')).to eq('docker')
    explicit = cli('config', 'show', '--container-engine', 'podman')
    expect(YAML.safe_load(explicit.stdout).dig('runtime', 'container_engine')).to eq('podman')
  end

  it 'displays defaults and validates them successfully' do
    result = cli('config', 'show')
    expect(result).to be_success
    expect(YAML.safe_load(result.stdout)['runtime']['container_engine']).to eq('podman')
    expect(cli('config', 'validate')).to be_success
  end

  it 'loads a selected repository and honors runtime overrides' do
    File.write(File.join(@directory, '.empeira.yaml'), "node_defaults:\n  memory: 4096\n")
    result = cli('config', 'show', '--container-engine', 'docker')
    expect(result).to be_success
    data = YAML.safe_load(result.stdout)
    expect(data['runtime']['container_engine']).to eq('docker')
    expect(data['node_defaults']).to include('memory' => 4096, 'cpus' => 2)
  end

  it 'returns a useful failure for invalid YAML configuration' do
    File.write(File.join(@directory, '.empeira.yaml'), 'node_defaults: {cpus: 0}')
    result = cli('config', 'validate')
    expect(result.exit_status).to eq(1)
    expect(result.stderr).to include('node_defaults.cpus must be a positive integer')
    expect(result.stdout).to be_empty
  end

  it 'documents SSH as an explicit command and retains full validation for existing-resource access' do
    expect(cli('node', 'help').stdout).to include('ssh HOSTNAME', 'shell HOSTNAME')
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('proxy' => { 'global' => ['https://invalid.example'] }))
    %w[shell ssh logs list stop destroy].each do |operation|
      args = ['node', operation]
      args << 'test-node' unless operation == 'list'
      expect(cli(*args).stderr).to include('proxy.global')
    end
  end

  it 'reports skipped optional Hiera mounts and rejects unsupported fields' do
    mount = { 'source' => '../absent', 'type' => 'module', 'name' => 'hieradata' }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('hiera' => { 'mounts' => [mount] }))
    result = cli('config', 'show')
    expect(result).to be_success
    effective = YAML.safe_load(result.stdout).fetch('effective_hiera_mounts').first
    expect(effective).to include('status' => 'skipped', 'required' => false,
                                 'destination' => '/etc/puppetlabs/code/environments/production/modules/hieradata')
    File.write(File.join(@directory, '.empeira.yaml'), 'hiera: {directories: []}')
    expect(cli('config', 'validate').stderr).to include('hiera.directories is not a supported configuration key')
  end

  it 'reports workspace status using the infrastructure service' do
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {})
    app = Empeira::Application.new(project_path: @directory, runner: RuntimeExecution.new, locations: locations)
    allow(Empeira::Application).to receive(:new).and_return(app)
    expect { described_class.start(['status']) }
      .to output(/Workspace:.*Empeira version:.*Infrastructure: down.*Infrastructure fingerprint:/m).to_stdout
  end

  %w[self-update].concat(%w[all].map { |target| "update #{target}" }).each do |command|
    it "returns non-success for unavailable #{command}" do
      result = cli(*command.split)
      expect(result.exit_status).to eq(1)
      expect(result.stderr).to match(/not implemented|unavailable/)
    end
  end

  it 'routes update modules through the independent update plane' do
    application = Empeira::Application.new(project_path: @directory)
    service = instance_double(Empeira::Updates::Service)
    allow(application).to receive(:updates).and_return(service)
    expect(application).not_to receive(:infrastructure)
    allow(Empeira::Application).to receive(:new).and_return(application)
    expect(service).to receive(:update).with('modules')
    described_class.start(%w[update modules])
  end

  it 'keeps read-only commands usable with an unsatisfied requirement' do
    File.write(File.join(@directory, '.empeira.yaml'), 'requirements: {empeira: ">= 999.0"}')
    %w[show validate].each { |operation| expect(cli('config', operation)).to be_success }
    expect(cli('--version')).to be_success
    expect(cli('up').stderr).to include('version requirement is not satisfied')
    expect(cli('down').stderr).to include('version requirement is not satisfied')
  end

  it 'defaults node run to container and accepts an explicit container provider identically' do
    service = instance_double(Empeira::Node::Service)
    allow(Empeira::Node::Service).to receive(:new).and_return(service)
    expect(service).to receive(:run).twice do |request|
      expect(request.provider).to eq('container')
    end
    described_class.start(%w[node run host1])
    described_class.start(%w[node run host1 --provider container])
    expect(cli('node', 'help', 'run').stdout).to include('default: container')
  end

  it 'rejects unknown logical providers' do
    result = cli('node', 'run', 'host1', '--provider', 'qemu')
    expect(result).not_to be_success
    expect(result.stderr).to include('container', 'vm')
  end

  it 'turns node options into a provider-neutral request' do
    service = instance_double(Empeira::Node::Service)
    allow(Empeira::Node::Service).to receive(:new).and_return(service)
    expect(service).to receive(:run) do |request|
      expect(request.to_h).to eq(hostname: 'host1', provider: 'vm', os: 'debian', version: '12',
                                 memory: 2048, cpus: 4)
    end
    described_class.start(['node', 'run', 'host1', '--provider', 'vm', '--os', 'debian', '--version', '12',
                           '--memory', '2048', '--cpus', '4'])
  end

  it 'rejects the removed per-node Internet switches' do
    %w[--internet --no-internet].each do |option|
      result = cli('node', 'run', 'host1', option)
      expect(result).not_to be_success
      expect(result.stderr).to include('Unknown switches')
    end
  end

  %w[0 -2 2.5 invalid].each do |memory|
    it "rejects invalid memory override #{memory}" do
      result = cli('node', 'run', 'host1', '--provider', 'container', '--memory', memory)
      expect(result.exit_status).to eq(1)
      expect(result.stderr).to include('node_defaults.memory must be a positive integer')
    end
  end

  it 'requires the shared control plane before a VM can start' do
    result = cli('node', 'run', 'host1', '--provider', 'vm')
    expect(result.exit_status).to eq(1)
    expect(result.stderr).to include('empeira up first')
  end

  [
    %w[images list]
  ].each do |command|
    it "explicitly fails for the future command #{command.join(' ')}" do
      result = cli(*command)
      expect(result.exit_status).to eq(1)
      expect(result.stderr).to include('This command is not implemented yet.')
    end
  end

  it 'lists an empty workspace and gives actionable errors for absent nodes' do
    expect(cli('node', 'list')).to be_success
    expect(cli('node', 'list').stdout).to include('HOSTNAME PROVIDER RUNTIME')
    runtime = instance_double(Empeira::Runtime::Container, check_available!: true)
    allow(Empeira::Runtime::Podman).to receive(:new).and_return(runtime)
    expect do
      described_class.start(['node', 'run', 'host1', '--provider', 'container'])
    end.to raise_error(Empeira::Error, /empeira up first/)
    %w[start stop puppet shell ssh logs].each do |operation|
      expect do
        described_class.start(['node', operation, 'missing'])
      end.to raise_error(Empeira::Providers::NotFound, /Node does not exist/)
    end
  end

  it 'passes through the SSH client exit status without creating a progress overlay' do
    result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 7, timed_out: false)
    nodes = instance_double(Empeira::Node::Service)
    allow(Empeira::Node::Service).to receive(:new).and_return(nodes)
    expect(nodes).to receive(:ssh).with(name: 'host1', user: nil, identity: nil).and_return(result)
    expect(Empeira::CLI::ProgressRenderer).not_to receive(:new)
    expect do
      described_class.start(%w[node ssh host1])
    end.to raise_error(SystemExit) { |error| expect(error.status).to eq(7) }
  end

  it 'passes independent SSH user and identity overrides to the node service' do
    result = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
    nodes = instance_double(Empeira::Node::Service)
    allow(Empeira::Node::Service).to receive(:new).and_return(nodes)
    expect(nodes).to receive(:ssh).with(name: 'host1', user: 'deploy', identity: '/synthetic/key').and_return(result)
    described_class.start(['node', 'ssh', 'host1', '--user', 'deploy', '--identity', '/synthetic/key'])
    expect(cli('node', 'help', 'ssh').stdout).to include('--user', '--identity')
  end

  it 'explains additive proxy policy without requiring a running node' do
    proxy = { 'enabled' => true, 'global' => ['forgeapi.puppet.com'],
              'rules' => [{ 'hosts' => ['*-web-*'], 'allow' => ['github.com'] }] }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('proxy' => proxy))
    result = cli('proxy', 'show', 'LAB-web-1-01.example')
    expect(result).to be_success
    expect(result.stdout).to include('lab-web-1-01.example', 'Global:', 'Matched rules:',
                                     '*-web-*', 'Allowed:', 'github.com', 'All workspace nodes may use this policy',
                                     'bootstrap destinations are separate')
  end

  it 'rejects unknown commands and misspelled options' do
    expect(cli('unknown')).not_to be_success
    expect(cli('config', 'show', '--contaner-engine', 'docker')).not_to be_success
  end
end
