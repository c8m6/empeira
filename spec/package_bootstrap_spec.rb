# frozen_string_literal: true

RSpec.describe Empeira::Node::PackageBootstrap do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:copy) { ->(_source, _destination, _mode) {} }
  let(:config) do
    {
      'install' => { 'default' => %w[git curl], 'debian' => ['libxml2-dev'], 'redhat' => ['libxml2-devel'] },
      'remove' => { 'default' => ['telnet'], 'debian' => [], 'redhat' => [] }
    }
  end

  %w[ubuntu debian].each do |os|
    it "combines default and Debian packages for #{os}, removing before installing" do
      calls = []
      execute = lambda do |arguments|
        calls << arguments
        arguments.first == 'cat' ? success.with(stdout: "[main]\ngpgcheck=1\n") : success
      end
      bootstrap = described_class.new(config: config, os: os, execute: execute, copy: copy)
      bootstrap.run(proxy_url: 'http://proxy.test:3128')
      expect(calls.first(3).map(&:first)).to eq(%w[apt-get apt-get apt-get])
      expect(calls.first(3)).to all(include('-c', Empeira::Node::PackageProxy::APT_PATH))
      expect(calls[0]).to include('remove', 'telnet')
      expect(calls[1]).to include('update')
      expect(calls[2]).to include('install', 'git', 'curl', 'libxml2-dev')
      expect(calls.size).to eq(4)
    end
  end

  %w[rhel rocky almalinux].each do |os|
    it "combines default and Red Hat packages for #{os}" do
      calls = []
      execute = lambda do |arguments|
        calls << arguments
        arguments.first == 'cat' ? success.with(stdout: "[main]\ngpgcheck=1\n") : success
      end
      bootstrap = described_class.new(config: config, os: os, execute: execute, copy: copy)
      bootstrap.run(proxy_url: 'http://proxy.test:3128')
      manager_calls = calls.select { |args| args.first == 'dnf' }
      expect(manager_calls.size).to eq(3)
      expect(manager_calls[2]).to include('install', 'git', 'curl', 'libxml2-devel')
    end
  end

  it 'does not invoke a package manager for empty package lists' do
    empty = config.transform_values { |groups| groups.transform_values { [] } }
    bootstrap = described_class.new(config: empty, os: 'ubuntu', execute: ->(*) { raise 'unexpected execution' })
    expect(bootstrap).not_to be_required
    expect { bootstrap.run(proxy_url: 'http://proxy.test:3128') }.not_to raise_error
  end

  it 'stops after a failed removal and reports that Puppet was not run' do
    failure = Empeira::Execution::Result.new(stdout: '', stderr: 'error: repository URL http://secret@proxy/',
                                             exit_status: 17, timed_out: false)
    execute = ->(args) { args.first == 'apt-get' ? failure : success }
    bootstrap = described_class.new(config: config, os: 'ubuntu', execute: execute, copy: copy)
    expect { bootstrap.run(proxy_url: 'http://proxy.test:3128') }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('remove failed', 'exit=17', 'http://proxy/', 'Puppet was not run')
        expect(error.message).not_to include('secret@')
      end
  end

  it 'reports bounded remove, metadata and install progress without package-manager output' do
    messages = []
    bootstrap = described_class.new(config: config, os: 'ubuntu', execute: ->(*) { success }, copy: copy,
                                    progress: ->(message) { messages << message })
    bootstrap.run(proxy_url: 'http://proxy.test:3128')
    expect(messages).to eq(['Removing 1 package...', 'Refreshing package metadata...', 'Installing 3 packages...'])
  end

  it 'deep merges partial project package groups over the empty defaults' do
    project = { 'bootstrap' => { 'packages' => { 'install' => { 'default' => ['git'] },
                                                 'remove' => { 'redhat' => ['telnet'] } } } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(project))
    packages = Empeira::Application.new(project_path: @directory).context.configuration.dig('bootstrap', 'packages')
    expect(packages).to eq(
      'install' => { 'default' => ['git'], 'debian' => [], 'redhat' => [] },
      'remove' => { 'default' => [], 'debian' => [], 'redhat' => ['telnet'] }
    )
  end

  it 'rejects unknown groups, option-shaped values and whitespace in package names' do
    invalid = [
      { 'install' => { 'ubuntu' => ['git'] } },
      { 'install' => { 'default' => ['--allow-downgrades'] } },
      { 'remove' => { 'debian' => ['bad package'] } }
    ]
    invalid.each do |packages|
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('bootstrap' => { 'packages' => packages }))
      expect { Empeira::Application.new(project_path: @directory).context.configuration }
        .to raise_error(Empeira::ConfigurationError, /bootstrap.packages/)
    end
  end
end
