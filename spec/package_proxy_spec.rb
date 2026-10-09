# frozen_string_literal: true

RSpec.describe 'Private native package proxy configuration' do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:url) { 'http://bootstrap:temporary-secret@proxy.test:3128' }
  let(:files) { {} }
  let(:captured) { [] }
  let(:calls) { [] }
  let(:copy) do
    lambda do |path, destination, mode|
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(mode).to eq('0600')
      captured << File.read(path)
      files[destination] = File.read(path)
    end
  end
  let(:config) do
    { 'install' => { 'default' => ['git'], 'debian' => [], 'redhat' => [] },
      'remove' => { 'default' => [], 'debian' => [], 'redhat' => [] } }
  end

  %w[ubuntu rocky].each do |os|
    it "cleans private configuration after a #{os} failure without leaking raw credentials" do
      execute = lambda do |args|
        calls << args
        case args.first
        when 'cat'
          success.with(stdout: "[main]\ninstallonly_limit=3\nproxy=http://original\n" \
                               "proxy_username=original-user\nproxy_password=original-password\n" \
                               "sslverify=0\nlogfilelevel=9\n")
        when 'rm'
          args.each { |path| files.delete(path) }
          success
        else success.with(exit_status: 1, stderr: 'error: temporary-secret authentication failed')
        end
      end
      bootstrap = Empeira::Node::PackageBootstrap.new(config: config, os: os, execute: execute, copy: copy)
      expect { bootstrap.run(proxy_url: url) }.to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('authentication failed', '[REDACTED]')
        expect(error.message).not_to include('temporary-secret')
      end
      expect(calls.flatten.join(' ')).not_to include('temporary-secret', url)
      if os == 'rocky'
        expect(captured.join).to include('proxy=http://proxy.test:3128', 'proxy_username=bootstrap',
                                         'proxy_password=temporary-secret', 'proxy_auth_method=basic')
      else
        expect(captured.join).to include(url)
      end
      expect(files).to be_empty
      expect(captured.join).to include('installonly_limit=3', 'logfilelevel=0', 'sslverify=1') if os == 'rocky'
      expect(captured.join).not_to include('sslverify=0')
      expect(captured.join).not_to include('original-user', 'original-password')
    end
  end

  it 'reports unverifiable cleanup instead of allowing a successful bootstrap result' do
    execute = ->(args) { args.first == 'rm' ? success.with(exit_status: 1) : success }
    bootstrap = Empeira::Node::PackageBootstrap.new(config: config, os: 'ubuntu', execute: execute, copy: copy)
    expect { bootstrap.run(proxy_url: url) }.to raise_error(Empeira::Error, /Cannot remove.*Puppet was not run/)
  end

  %w[bootstrap agent].product(%w[proxy repository]).each do |installer, origin|
    it "redacts #{origin} credentials before truncating #{installer} diagnostics" do
      secret = 's' * 64
      endpoint = origin == 'proxy' ? "http://bootstrap:#{secret}@proxy.test:3128" : url
      if origin == 'repository'
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('EMPEIRA_AGENT_REPO_USERNAME', nil).and_return('fixture-user')
        allow(ENV).to receive(:fetch).with('EMPEIRA_AGENT_REPO_PASSWORD', nil).and_return(secret)
      end
      execute = lambda do |args|
        args.first == 'rm' ? success : success.with(exit_status: 1, stderr: "#{'x' * 475} #{secret} denied")
      end
      invoke = if installer == 'bootstrap'
                 instance = Empeira::Node::PackageBootstrap.new(config: config, os: 'ubuntu', execute: execute,
                                                                copy: copy)
                 -> { instance.run(proxy_url: endpoint) }
               else
                 target = Empeira::Agent::Target.new(os: 'ubuntu', release: '24.04', architecture: 'amd64')
                 artifact_path = Pathname(@directory).join('synthetic.deb')
                 File.write(artifact_path, 'synthetic', perm: 0o600)
                 artifact = Empeira::Agent::Artifact.new(path: artifact_path, metadata: {})
                 instance = Empeira::Node::AgentPackage.new(target: target, package: 'synthetic-agent',
                                                            artifact: artifact, execute: execute, copy: copy)
                 -> { instance.install(proxy_url: endpoint) }
               end
      expect(&invoke).to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('[REDACTED]')
        expect(error.message).not_to include(secret[0, 20])
      end
    end
  end
end
