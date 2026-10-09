# frozen_string_literal: true

require_relative '../resources/nodes/apt_sources'

RSpec.describe Empeira::AptSources do
  let(:root) { Pathname(@directory) }
  let(:sources) { root.join('etc/apt/sources.list.d') }
  let(:checker) { described_class.new(root) }

  before { sources.mkpath }

  %w[ubuntu debian].each do |distribution|
    context distribution do
      before { root.join('etc/os-release').write("ID=#{distribution}\n") }

      it 'accepts distribution deb822 sources without a legacy sources.list and leaves them unchanged' do
        path = sources.join("#{distribution}.sources")
        path.write("Types: deb deb-src\nURIs: https://mirror.example.test/archive\n" \
                   "Suites: stable stable-updates\nComponents: main\n  contrib\n")
        original = [path.read, path.stat.ino, path.stat.mtime]
        2.times { expect(checker).to be_valid }
        expect([path.read, path.stat.ino, path.stat.mtime]).to eq(original)
      end

      it 'accepts legacy sources, including architecture and signature options' do
        root.join('etc/apt/sources.list').write(
          "deb [arch=arm64 signed-by=/usr/share/keyrings/archive.gpg] https://mirror.example.test/archive stable main\n"
        )
        expect(checker).to be_valid
      end

      it 'rejects empty, commented, disabled and agent-only sources without repairing Puppet policy' do
        root.join('etc/apt/sources.list').write("# Repos managed by puppet.\n")
        expect(checker).not_to be_valid
        path = sources.join('disabled.sources')
        path.write("Enabled: no\nTypes: deb\nURIs: https://mirror.example.test\nSuites: stable\nComponents: main\n")
        sources.join('agent.list').write("deb https://agent.example.test noble openvox8\n")
        expect(checker).not_to be_valid
        expect(root.join('etc/apt/sources.list').read).to eq("# Repos managed by puppet.\n")
        expect(path.read).to start_with('Enabled: no')
      end
    end
  end

  it 'does not require APT on an RPM distribution' do
    root.join('etc/os-release').write("ID=rocky\n")
    expect(checker).to be_valid
  end

  it 'stops before Puppet and retains sanitized native diagnostics on a failed guest check' do
    failure = Empeira::Execution::Result.new(stdout: 'no active sources', stderr: 'password=synthetic-secret',
                                             exit_status: 1, timed_out: false)
    operation = -> { Empeira::Node::PackageSources.verify!(execute: ->(_arguments) { failure }) }
    expect(&operation).to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('Puppet was not run', 'no active sources', 'Exit code: 1', 'Timeout: false')
      expect(error.full_message).not_to include('synthetic-secret')
    end
  end
end
