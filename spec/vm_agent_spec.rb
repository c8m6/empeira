# frozen_string_literal: true

RSpec.describe Empeira::VM::Agent do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:ssh) { instance_double(Empeira::VM::SSH) }
  let(:record) { { 'os' => 'ubuntu', 'version' => '24.04', 'architecture' => 'amd64' } }
  let(:success) { Empeira::Execution::Result.new(stdout: app.context.configuration.dig('agent', 'version'), stderr: '', exit_status: 0, timed_out: false) }
  let(:failure) { success.with(exit_status: 1) }

  it 'uses the shared repository installer with the OpenVox package by default' do
    requirements = Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04')
    installer = instance_double(Empeira::Node::AgentRepository, install: nil)
    expect(Empeira::Node::AgentRepository).to receive(:new).with(
      source: requirements.repository, package: app.context.configuration.dig('agent', 'package'),
      version: app.context.configuration.dig('agent', 'version'),
      execute: an_instance_of(Proc), copy: an_instance_of(Proc)
    ).and_return(installer)
    allow(ssh).to receive(:run).and_return(success)
    described_class.new(context: app.context, ssh: ssh).ensure_installed(record, requirements: requirements,
                                                                                 proxy_url: 'http://bootstrap.example.net:3128')
    expect(installer).to have_received(:install).with(proxy_url: 'http://bootstrap.example.net:3128')
  end

  it 'uses the direct package installer without changing the server' do
    source = { 'url' => 'https://packages.example.net/agent.deb', 'sha256' => 'a' * 64 }
    agent = { 'package' => 'puppet-agent', 'version' => '8.20.0',
              'install' => { 'method' => 'package', 'packages' => { 'ubuntu24.04' => { 'amd64' => source } } } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('agent' => agent))
    requirements = Empeira::VM::BootstrapRequirements.new(context: app.context, os: 'ubuntu', version: '24.04',
                                                          architecture: 'amd64')
    installer = instance_double(Empeira::Node::AgentPackage, install: nil)
    expect(Empeira::Node::AgentPackage).to receive(:new).with(
      os: 'ubuntu', rpm_options: [], source: source, package: 'puppet-agent', version: '8.20.0',
      execute: an_instance_of(Proc), copy: an_instance_of(Proc)
    ).and_return(installer)
    allow(ssh).to receive(:run).and_return(success)
    described_class.new(context: app.context, ssh: ssh).ensure_installed(record, requirements: requirements,
                                                                                 proxy_url: 'http://bootstrap.example.net:3128')
    expect(app.context.configuration.dig('images', 'server'))
      .to eq(Empeira::Configuration::Loader.new(project_path: @directory).load_defaults.dig('images', 'server'))
  end

  it 'fails closed when no managed bootstrap proxy is provided' do
    allow(ssh).to receive(:run).and_return(failure)
    expect { described_class.new(context: app.context, ssh: ssh).ensure_installed(record) }
      .to raise_error(Empeira::Error, /bootstrap proxy/)
  end
end
