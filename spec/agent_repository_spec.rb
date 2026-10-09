# frozen_string_literal: true

RSpec.describe 'Native agent package acquisition' do
  let(:calls) { [] }
  let(:files) { {} }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:source) { { 'url' => 'https://packages.example.org/apt', 'suite' => 'noble', 'component' => 'main' } }
  let(:target) { Empeira::Agent::Target.new(os: 'ubuntu', release: '24.04', architecture: 'amd64') }
  let(:authentication) { Empeira::Agent::Authentication.new(url: source.fetch('url')) }
  let(:download) { instance_double(Empeira::Agent::Download) }
  let(:copy) { ->(path, destination, mode) { files[destination] = [File.binread(path), mode] } }
  let(:catalog) do
    "Package: synthetic-agent\nVersion: 1.2.3-1noble\nArchitecture: amd64\nFilename: agent.deb\nSHA256: #{'a' * 64}\n\n"
  end
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      output = case arguments.first
               when 'apt-cache' then catalog
               when 'apt-get'
                 arguments.include?('--print-uris') ? "'https://packages.example.org/agent.deb' agent.deb 100\n" : ''
               when 'dpkg-deb' then 'synthetic-agent|1.2.3-1noble|amd64'
               else ''
               end
      success.with(stdout: output)
    end
  end
  let(:resolver) do
    Empeira::Node::AgentRepository.new(source: source, package: 'synthetic-agent', version: '1.2.3',
                                       target: target, execute: execute, copy: copy, download: download,
                                       authentication: authentication, directory: @directory)
  end

  it 'selects the full native version from only the isolated source and target architecture' do
    candidate = resolver.resolve
    expect(candidate).to include('version' => '1.2.3-1noble', 'sha256' => 'a' * 64)
    expect(calls.flatten).to include('Dir::State::status=/dev/null', 'Dir::Etc::sourceparts=/var/tmp/empeira-agent-sources')
    expect(files.fetch(Empeira::Node::AgentRepository::SOURCE_PATH).first).not_to include('trusted=yes')
  end

  it 'rejects ambiguous native releases without selecting the latest' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      result = method.call(arguments)
      arguments.first == 'apt-cache' ? result.with(stdout: catalog + catalog.sub('1noble', '2noble')) : result
    end
    expect { resolver.resolve }.to raise_error(Empeira::Error, /ambiguous/)
  end

  it 'rejects versions unavailable in the selected source or wrong target architecture' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      result = method.call(arguments)
      arguments.first == 'apt-cache' ? result.with(stdout: catalog.sub('amd64', 'arm64')) : result
    end
    expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
  end

  it 'writes origin-scoped private authentication with exact UTF-8 values and no credentials in argv' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'synthetic-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-ü-password'
    resolver.resolve
    content, mode = files.fetch(Empeira::Node::AgentRepository::AUTH_PATH)
    expect(content.force_encoding(Encoding::UTF_8)).to include(
      'machine https://packages.example.org', 'login "synthetic-user"', 'password "synthetic-ü-password"'
    )
    expect(mode).to eq('0600')
    expect(calls.flatten.join(' ')).not_to include('synthetic-user', 'synthetic-ü-password')
  end

  it 'disables signature verification only for the explicit source' do
    source['verify_signatures'] = false
    resolver.resolve
    expect(files.fetch(Empeira::Node::AgentRepository::SOURCE_PATH).first).to include('[trusted=yes]')
    expect(calls.flatten.join(' ')).not_to include('AllowUnauthenticated', 'AllowInsecureRepositories=true')
  end

  it 'retains native signature errors instead of falling back to an unsigned source' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      arguments.include?('update') ? success.with(exit_status: 1, stderr: 'error: NO_PUBKEY') : method.call(arguments)
    end
    expect { resolver.resolve }.to raise_error(Empeira::Error, /NO_PUBKEY/)
  end

  it 'inspects package metadata before installing and rejects a different identity' do
    path = Pathname(@directory).join('agent.deb')
    path.write('synthetic')
    expect(resolver.inspect_package(path)).to include('version' => '1.2.3-1noble')
    allow(execute).to receive(:call).and_return(success.with(stdout: 'other-agent|1.2.3-1noble|amd64'))
    expect { resolver.inspect_package(path) }.to raise_error(Empeira::Error, /differs/)
  end
end

RSpec.describe Empeira::Agent::Versions do
  it 'supports a software version, an explicit native version, epochs and suffix overrides without version ordering' do
    candidates = [{ 'version' => '1:8.20.0-1.el9' }]
    expect(described_class.select(candidates, '8.20.0')).to eq(candidates.first)
    expect(described_class.select(candidates, '1:8.20.0-1.el9')).to eq(candidates.first)
    expect(described_class.select([{ 'version' => '8.20.0-1.el9' }], '8.20.0', suffix: '-1.el9'))
      .to eq('version' => '8.20.0-1.el9')
    expect { described_class.select(candidates, '8.20.1') }.to raise_error(Empeira::Error, /unavailable/)
  end
end
