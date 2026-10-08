# frozen_string_literal: true

RSpec.describe 'Agent release-package transaction ownership' do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:source) { { 'url' => 'https://packages.example.net/release', 'sha256' => 'a' * 64, 'suffix' => '-1' } }
  let(:installed) { [] }
  let(:calls) { [] }
  let(:files) { {} }
  let(:failure) { nil }
  let(:copy) { ->(path, destination, mode) { files[destination] = [File.read(path), mode] } }
  let(:execute) do
    lambda do |args|
      calls << args
      if args.include?('-qa') || args.include?('-f=${Package}\n')
        failure == :query ? success.with(exit_status: 2) : success.with(stdout: installed.join("\n"))
      elsif args.include?('-i')
        installed << 'agent-release'
        failure == :install ? success.with(exit_status: 1, stderr: 'error: installation failed') : success
      elsif args.include?('--purge') || args.include?('-e')
        next success.with(exit_status: 1, stderr: 'error: cleanup failed') if failure == :cleanup

        installed.delete('agent-release')
        success
      elsif args.first == 'rm'
        args.each { |path| files.delete(path) }
        success
      else
        output = case args.first
                 when 'cat' then "[main]\ngpgcheck=1\n"
                 when 'sha256sum' then "#{source.fetch('sha256')}  artifact\n"
                 when 'dpkg-deb' then 'agent-release'
                 when 'rpm' then args.include?('-qp') ? 'agent-release' : '1.2.3-1'
                 when 'dpkg-query' then '1.2.3-1'
                 else ''
                 end
        success.with(stdout: output)
      end
    end
  end

  around do |example|
    previous = ENV.to_h
    ENV.delete('EMPEIRA_AGENT_REPO_USERNAME')
    ENV.delete('EMPEIRA_AGENT_REPO_PASSWORD')
    example.run
  ensure
    ENV.replace(previous)
  end

  [Empeira::Node::AgentRepository, Empeira::Node::DnfAgentRepository].each do |klass|
    context klass.name do
      let(:installer) do
        klass.new(source: source, package: 'synthetic-agent', version: '1.2.3', execute: execute, copy: copy)
      end

      it 'removes only its introduced release package after success' do
        installed << 'unrelated-release'
        installer.install(proxy_url: 'http://bootstrap:temporary@proxy.test:3128')
        expect(installed).to eq(['unrelated-release'])
        expect(calls.flatten.join(' ')).not_to include('temporary')
        expect(files).to be_empty
      end

      it 'rejects preexisting installed or configuration-only package records without installation or removal' do
        installed << 'agent-release'
        expect do
          installer.install(proxy_url: 'http://proxy.test:3128')
        end.to raise_error(Empeira::Error, /already exists/)
        expect(calls).not_to include(array_including('-i'))
        expect(calls).not_to include(array_including('--purge'))
        expect(calls).not_to include(array_including('-e'))
        expect(installed).to eq(['agent-release'])
        expect(files).to be_empty
      end

      it 'does not retain package ownership from an earlier completed transaction' do
        installer.install(proxy_url: 'http://proxy.test:3128')
        calls.clear
        installed << 'agent-release'
        expect do
          installer.install(proxy_url: 'http://proxy.test:3128')
        end.to raise_error(Empeira::Error, /already exists/)
        expect(calls).not_to include(array_including('--purge'), array_including('-e'))
        expect(installed).to eq(['agent-release'])
      end

      context 'when the original package database cannot be queried' do
        let(:failure) { :query }

        it 'fails before installation or destructive cleanup' do
          expect { installer.install(proxy_url: 'http://proxy.test:3128') }.to raise_error(Empeira::Error, /ownership/)
          expect(calls).not_to include(array_including('-i'))
          expect(installed).to be_empty
        end
      end

      context 'when installation fails after introducing partial package state' do
        let(:failure) { :install }

        it 'cleans up the introduced package and private configuration' do
          expect do
            installer.install(proxy_url: 'http://proxy.test:3128')
          end.to raise_error(Empeira::Error, /installation failed/)
          expect(installed).to be_empty
          expect(files).to be_empty
        end
      end

      context 'when native package cleanup fails' do
        let(:failure) { :cleanup }

        it 'reports failure and still removes private proxy and download files' do
          expect { installer.install(proxy_url: 'http://proxy.test:3128') }.to raise_error(Empeira::Error, /cleanup/)
          expect(installed).to eq(['agent-release'])
          expect(files).to be_empty
        end
      end
    end
  end

  it 'rejects authenticated DNF release RPMs before guest mutation, directing users to scoped sources' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'synthetic-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-password'
    installer = Empeira::Node::DnfAgentRepository.new(source: source, package: 'synthetic-agent', version: '1.2.3',
                                                      execute: execute, copy: copy)
    expect { installer.install(proxy_url: 'http://proxy.test:3128') }
      .to raise_error(Empeira::ConfigurationError, /Authenticated DNF.*agent.install.dnf/)
    expect(calls).to be_empty
    expect(files).to be_empty
  end
end
