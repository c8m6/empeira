# frozen_string_literal: true

RSpec.describe 'Agent helper release-package ownership' do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:installed) { [] }
  let(:calls) { [] }
  let(:failure) { nil }
  let(:download) { instance_double(Empeira::Agent::Download) }
  let(:copy) { ->(_path, _destination, _mode) {} }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      if arguments.include?('-qa') || arguments.include?('-f=${Package}\n')
        failure == :query ? success.with(exit_status: 2) : success.with(stdout: installed.join("\n"))
      elsif arguments.include?('-i')
        installed << 'agent-release'
        failure == :install ? success.with(exit_status: 1, stderr: 'error: installation failed') : success
      elsif arguments.include?('--purge') || arguments.include?('-e')
        next success.with(exit_status: 1, stderr: 'error: cleanup failed') if failure == :cleanup

        installed.delete('agent-release')
        success
      elsif arguments.include?('-qp') || arguments.include?('--field')
        success.with(stdout: 'agent-release')
      else
        success
      end
    end
  end

  [Empeira::Node::AgentRepository, Empeira::Node::DnfAgentRepository].each do |klass|
    context klass.name do
      let(:source) { { 'url' => "https://packages.example.org/release.#{klass == Empeira::Node::AgentRepository ? 'deb' : 'rpm'}", 'suffix' => '-1' } }
      let(:target) { Empeira::Agent::Target.new(os: klass == Empeira::Node::AgentRepository ? 'ubuntu' : 'rocky', release: '9', architecture: 'amd64') }
      let(:resolver) do
        klass.new(source: source, package: 'synthetic-agent', version: '1.2.3', target: target,
                  execute: execute, copy: copy, download: download,
                  authentication: Empeira::Agent::Authentication.new(url: source.fetch('url')), directory: @directory)
      end

      before do
        allow(download).to receive(:fetch) { |_, path, **| File.write(path, 'synthetic') }
        allow(resolver).to receive(:collect_release_sources)
      end

      it 'removes only the release package introduced into its disposable helper' do
        installed << 'unrelated-package'
        expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
        expect(installed).to eq(['unrelated-package'])
      end

      it 'rejects preexisting release records without replacing or deleting them' do
        installed << 'agent-release'
        expect { resolver.resolve }.to raise_error(Empeira::Error, /already exists/)
        expect(calls).not_to include(array_including('-i'), array_including('-e'), array_including('--purge'))
        expect(installed).to eq(['agent-release'])
      end

      it 'does not reuse package ownership from an earlier transaction' do
        expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
        installed << 'agent-release'
        calls.clear
        expect { resolver.resolve }.to raise_error(Empeira::Error, /already exists/)
        expect(installed).to eq(['agent-release'])
      end

      context 'with unreadable original package state' do
        let(:failure) { :query }

        it 'fails before native package mutation' do
          expect { resolver.resolve }.to raise_error(Empeira::Error, /ownership/)
          expect(calls).not_to include(array_including('-i'))
        end
      end

      context 'with a partial release install' do
        let(:failure) { :install }

        it 'removes only the newly introduced package even after failure' do
          expect { resolver.resolve }.to raise_error(Empeira::Error, /installation failed/)
          expect(installed).to be_empty
        end
      end

      context 'with failed release cleanup' do
        let(:failure) { :cleanup }

        it 'fails the acquisition instead of reporting a usable artifact' do
          expect { resolver.resolve }.to raise_error(Empeira::Error, /cleanup/)
        end
      end
    end
  end
end
