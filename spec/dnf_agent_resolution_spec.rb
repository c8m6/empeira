# frozen_string_literal: true

RSpec.describe Empeira::Node::DnfAgentRepository do
  let(:calls) { [] }
  let(:files) { {} }
  let(:source) { { 'url' => 'https://packages.example.org/el/9/x86_64' } }
  let(:target) { Empeira::Agent::Target.new(os: 'rocky', release: '9', architecture: 'amd64') }
  let(:authentication) { Empeira::Agent::Authentication.new(url: source.fetch('url')) }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:catalog) { +"synthetic-agent|0|1.2.3|1.el9|x86_64|empeira-agent\n" }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      output = if arguments.include?('--location')
                 "https://packages.example.org/agent.rpm\n"
               elsif arguments.include?('repoquery')
                 catalog
               elsif arguments.include?('-qp')
                 'synthetic-agent|0:1.2.3-1.el9|x86_64'
               elsif arguments.include?('--checksig')
                 'RSA/SHA256 Signature: OK'
               else
                 ''
               end
      success.with(stdout: output)
    end
  end
  let(:copy) { ->(path, destination, mode) { files[destination] = [File.binread(path), mode] } }
  let(:resolver) do
    described_class.new(source: source, package: 'synthetic-agent', version: '1.2.3', target: target,
                        execute: execute, copy: copy, download: instance_double(Empeira::Agent::Download),
                        authentication: authentication, directory: @directory)
  end

  it 'uses native full versions and constrains location queries to the selected repository' do
    expect(resolver.resolve).to include('version' => '1.2.3-1.el9')
    expect(calls.flatten).to include('--archlist=x86_64,noarch', '--repoid=empeira-agent', '--releasever=9')
    expect(files.fetch(described_class::CONFIG_PATH).first).to include('reposdir=/var/tmp/empeira-agent-repos')
    expect(files.fetch(described_class::REPO_PATH).first).to include('gpgcheck=1', 'sslverify=1')
  end

  it 'rejects candidates supplied by foreign sources or the wrong architecture' do
    catalog.replace("synthetic-agent|0|1.2.3|1.el9|x86_64|foreign-repository\n")
    expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
    catalog.replace("synthetic-agent|0|1.2.3|1.el9|aarch64|empeira-agent\n")
    expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
  end

  it 'rejects ambiguous releases and never silently upgrades the software version' do
    catalog << "synthetic-agent|0|1.2.3|2.el9|x86_64|empeira-agent\n"
    expect { resolver.resolve }.to raise_error(Empeira::Error, /ambiguous/)
    catalog.replace("synthetic-agent|0|1.2.4|1.el9|x86_64|empeira-agent\n")
    expect { resolver.resolve }.to raise_error(Empeira::Error, /unavailable/)
  end

  it 'keeps TLS and default verification while allowing a scoped signature exception' do
    source['verify_signatures'] = false
    resolver.resolve
    expect(files.fetch(described_class::REPO_PATH).first).to include('gpgcheck=0', 'sslverify=1')
    expect(files.fetch(described_class::CONFIG_PATH).first).to include('gpgcheck=1', 'sslverify=1')
    path = Pathname(@directory).join('package.rpm')
    path.write('synthetic')
    expect(resolver.inspect_package(path)).to include('version' => '1.2.3-1.el9')
    expect(calls.flatten).not_to include('--checksig')
  end

  it 'requires a native verifiable RPM signature unless explicitly disabled' do
    path = Pathname(@directory).join('package.rpm')
    path.write('synthetic')
    expect(resolver.inspect_package(path)).to include('version' => '1.2.3-1.el9')
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      arguments.include?('--checksig') ? success.with(stdout: 'Header SHA256 digest: OK') : method.call(arguments)
    end
    expect { resolver.inspect_package(path) }.to raise_error(Empeira::Error, /no verifiable trusted signature/)
  end
end

RSpec.describe Empeira::Agent::ReleaseSources do
  it 'preserves native APT sources by default and scopes exceptions to selected list or deb822 sources' do
    source = "deb [signed-by=/etc/apt/keyrings/agent.gpg] https://packages.example.org/apt noble main\n"
    expect(described_class.apt(source, format: '.list', source: {})).to eq(source)
    unsigned = described_class.apt(source, format: '.list', source: { 'verify_signatures' => false })
    expect(unsigned).to include('signed-by=/etc/apt/keyrings/agent.gpg trusted=yes')
    deb822 = "Types: deb\nURIs: https://packages.example.org/apt\nSuites: noble\nComponents: main\n"
    expect(described_class.apt(deb822, format: '.sources', source: { 'verify_signatures' => false }))
      .to include('Trusted: yes')
    expect { described_class.apt(source.sub('https:', 'http:'), format: '.list', source: {}) }
      .to raise_error(Empeira::ConfigurationError, /HTTPS URL/)
  end

  it 'does not inherit unsigned or foreign protocol exemptions from a custom APT release package' do
    source = "deb [trusted=yes allow-insecure=yes] https://packages.example.org/apt noble main\n"
    expect(described_class.apt(source, format: '.list', source: {}))
      .to eq("deb https://packages.example.org/apt noble main\n")
    expect { described_class.apt(source.sub('https:', 'ftp:'), format: '.list', source: {}) }
      .to raise_error(Empeira::ConfigurationError, /HTTPS URL/)
  end

  it 'enforces scoped DNF signature policy, TLS and package selection on release-package sources' do
    target = Empeira::Agent::Target.new(os: 'rocky', release: '9', architecture: 'amd64')
    source = "[agent]\nbaseurl=https://packages.example.org/$releasever/$basearch\ngpgcheck=0\nsslverify=0\n"
    output = described_class.dnf(source, target: target, source: {}, package: 'synthetic-agent')
    expect(output).to include('gpgcheck=1', 'sslverify=1', 'includepkgs=synthetic-agent')
    expect(output).not_to include('sslverify=0')
    output = described_class.dnf(source, target: target, source: { 'verify_signatures' => false },
                                         package: 'synthetic-agent')
    expect(output).to include('gpgcheck=0', 'sslverify=1')
  end
end
