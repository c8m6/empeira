# frozen_string_literal: true

RSpec.describe Empeira::Node::AgentPackage do
  let(:target) { Empeira::Agent::Target.new(os: 'ubuntu', release: '24.04', architecture: 'amd64') }
  let(:calls) { [] }
  let(:files) { {} }
  let(:keys) { [] }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:path) { Pathname(@directory).join('agent.deb') }
  let(:artifact) do
    path.write('synthetic-package')
    Empeira::Agent::Artifact.new(path: path, metadata: {
                                   'version' => '1.2.3-1', 'architecture' => target.native_architecture,
                                   'public_keys' => [Base64.strict_encode64('synthetic-public-key')],
                                   'verify_signatures' => true
                                 })
  end
  let(:copy) { ->(source, destination, mode) { files[destination] = [File.binread(source), mode] } }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      keys << 'gpg-pubkey-ab12-ef34' if arguments.first == 'rpmkeys'
      keys.delete(arguments.last) if arguments.include?('-e')
      output = if arguments.include?('-qa')
                 keys.join("\n")
               elsif arguments.first == 'dpkg-query'
                 "synthetic-agent|1.2.3-1|#{target.native_architecture}"
               elsif arguments.first == 'rpm' && arguments.include?('-q')
                 "synthetic-agent|0:1.2.3-1|#{target.native_architecture}"
               elsif arguments.first == 'cat'
                 "[main]\ngpgcheck=1\n"
               else
                 ''
               end
      arguments.each { |argument| files.delete(argument) } if arguments.first == 'rm'
      success.with(stdout: output)
    end
  end
  let(:installer) do
    described_class.new(target: target, package: 'synthetic-agent', artifact: artifact, execute: execute, copy: copy)
  end

  it 'copies the host artifact, installs through the original APT sources and verifies the full native identity' do
    installer.install(proxy_url: 'http://bootstrap:temporary@proxy.test:3128')
    expect(calls).to include(array_including('apt-get', 'install', '/var/tmp/empeira-agent-package.deb'))
    expect(calls.flatten).not_to include('curl', 'wget', 'dpkg', 'temporary')
    expect(files).to be_empty
  end

  it 'cleans uploaded artifacts and blocks Puppet after a dependency failure' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      if arguments.include?('install')
        success.with(exit_status: 1,
                     stderr: 'error: dependency unavailable')
      else
        method.call(arguments)
      end
    end
    expect do
      installer.install(proxy_url: 'http://proxy.test:3128')
    end.to raise_error(Empeira::Error,
                       /dependencies.*Puppet was not run/)
    expect(files).to be_empty
  end

  context 'RPM guest' do
    let(:target) { Empeira::Agent::Target.new(os: 'rocky', release: '9', architecture: 'amd64') }

    it 'verifies local signatures and removes only newly introduced public keys' do
      keys << 'gpg-pubkey-aa11-bb22'
      installer.install(proxy_url: 'http://proxy.test:3128')
      expect(calls.flatten).to include('--setopt=localpkg_gpgcheck=1')
      expect(calls.flatten).not_to include('--setopt=gpgcheck=0')
      expect(keys).to eq(['gpg-pubkey-aa11-bb22'])
      expect(files).to be_empty
    end

    it 'disables only local package checks when explicitly requested' do
      installer.instance_variable_get(:@artifact).metadata['verify_signatures'] = false
      installer.install(proxy_url: 'http://proxy.test:3128')
      expect(calls.flatten).to include('--setopt=localpkg_gpgcheck=0')
      expect(calls.flatten).not_to include('--setopt=gpgcheck=0')
    end
  end
end
