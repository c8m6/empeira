# frozen_string_literal: true

RSpec.describe Empeira::Node::AgentRepository do
  let(:source) do
    { 'url' => 'https://packages.example.net/puppet', 'suite' => 'noble', 'component' => 'main',
      'suffix' => '-1noble',
      'key' => { 'url' => 'https://packages.example.net/key.gpg', 'sha256' => 'a' * 64 } }
  end
  let(:calls) { [] }
  let(:files) { {} }
  let(:release_installed) { [] }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      case arguments.first
      when 'sha256sum'
        success.with(stdout: "#{source.fetch('key').fetch('sha256')}  key.gpg\n")
      when 'dpkg-query'
        success.with(stdout: arguments.include?('-f=${Package}\n') ? release_installed.join("\n") : '8.12.0-1noble')
      when 'dpkg'
        release_installed << 'agent-release' if arguments.include?('-i')
        release_installed.clear if arguments.include?('--purge')
        success
      when 'dpkg-deb'
        success.with(stdout: 'agent-release')
      when 'rm'
        arguments.each { |path| files.delete(path) }
        success
      else
        success
      end
    end
  end
  let(:copy) do
    lambda do |path, destination, mode|
      files[destination] = [File.read(path), mode]
    end
  end
  let(:installer) do
    described_class.new(source: source, package: 'puppet-agent', version: '8.12.0',
                        execute: execute, copy: copy)
  end

  around do |example|
    previous = ENV.to_h
    ENV.delete('EMPEIRA_AGENT_REPO_USERNAME')
    ENV.delete('EMPEIRA_AGENT_REPO_PASSWORD')
    example.run
  ensure
    ENV.replace(previous)
  end

  it 'installs from a signed custom APT source without credentials' do
    configured_source = nil
    allow(copy).to receive(:call).and_wrap_original do |method, path, destination, mode|
      method.call(path, destination, mode)
      configured_source = files.fetch(destination).first if destination == described_class::SOURCE_PATH
    end
    installer.install(proxy_url: 'http://proxy.example.net:3128')
    expect(configured_source)
      .to eq("deb [signed-by=#{described_class::KEY_PATH}] https://packages.example.net/puppet noble main\n")
    expect(calls).to include(array_including('apt-get', 'install', '-y', '--', 'puppet-agent=8.12.0-1noble'))
    expect(calls.flatten).to include('Acquire::https::AllowRedirect=false')
    expect(files).not_to have_key(described_class::AUTH_PATH)
    expect(files).not_to have_key(described_class::APT_PROXY_PATH)
    expect(files).not_to have_key(described_class::CURL_CONFIG_PATH)
    expect(files).not_to have_key(described_class::SOURCE_PATH)
    expect(files).not_to have_key(described_class::KEY_PATH)
    expect(calls.flatten.join(' ')).not_to include('http://proxy.example.net:3128')
  end

  it 'uses scoped APT credentials in a 0600 file and removes them after success' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'forge-key'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    captured = nil
    host_mode = nil
    allow(copy).to receive(:call).and_wrap_original do |method, path, destination, mode|
      host_mode = File.stat(path).mode & 0o777 if destination == described_class::AUTH_PATH
      method.call(path, destination, mode)
      captured = files.fetch(destination) if destination == described_class::AUTH_PATH
    end

    installer.install(proxy_url: 'http://proxy.example.net:3128')
    expect(captured).to eq(["machine https://packages.example.net/puppet/\n" \
                            "login forge-key\npassword synthetic-secret\n", '0600'])
    expect(host_mode).to eq(0o600)
    expect(files).not_to have_key(described_class::AUTH_PATH)
    expect(calls.flatten.join(' ')).not_to include('synthetic-secret')
  end

  it 'removes a verified official release package after installation' do
    release = { 'url' => 'https://packages.example.net/public/agent-release-noble.deb',
                'sha256' => 'b' * 64 }
    source.delete('key')
    source['release'] = release
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'forge-key'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      if arguments.first == 'sha256sum'
        success.with(stdout: "#{release.fetch('sha256')}  release.deb\n")
      else
        method.call(arguments)
      end
    end
    installer.install(proxy_url: 'http://proxy.example.net:3128')
    expect(calls).to include(['dpkg', '-i', '/var/tmp/empeira-agent-release.deb'],
                             ['dpkg', '--purge', '--', 'agent-release'],
                             ['rm', '-f', '/var/tmp/empeira-agent-release.deb'])
    expect(files).not_to have_key(described_class::SOURCE_PATH)
    expect(files).not_to have_key(described_class::AUTH_PATH)
  end

  it 'explains a protected repository that rejects unauthenticated access' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      arguments.include?('update') ? success.with(stderr: '401 Unauthorized', exit_status: 100) : method.call(arguments)
    end
    expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
      .to raise_error(Empeira::Error, /authentication failed/)
    expect(files).not_to have_key(described_class::AUTH_PATH)
  end

  [nil, '', 'bad value'].each do |value|
    it "rejects incomplete authentication with password #{value.inspect}" do
      ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'forge-key'
      ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = value unless value.nil?
      expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
        .to raise_error(Empeira::ConfigurationError, /both nonempty/)
      expect(calls).to be_empty
    end
  end

  it 'rejects a password without a username before guest execution' do
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
      .to raise_error(Empeira::ConfigurationError, /both nonempty/)
    expect(calls).to be_empty
  end

  it 'removes authentication after an APT failure without revealing credentials' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'forge-key'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      if arguments.include?('update')
        success.with(stderr: '401 Unauthorized synthetic-secret', exit_status: 100)
      else
        method.call(arguments)
      end
    end

    expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('authentication failed', 'EMPEIRA_AGENT_REPO_PASSWORD')
        expect(error.message).not_to include('synthetic-secret')
      end
    expect(files).not_to have_key(described_class::AUTH_PATH)
  end

  { '403 Forbidden' => 'access denied', '404 Not Found' => 'unavailable',
    'NO_PUBKEY ABCDEF' => 'signature verification failed',
    "Version '8.12.0-1noble' for 'puppet-agent' was not found" => 'Available versions',
    'Received HTTP code 403 from proxy after CONNECT' => 'Bootstrap proxy access denied' }.each do |diagnostic, hint|
    it "diagnoses #{diagnostic}" do
      allow(execute).to receive(:call).and_wrap_original do |method, arguments|
        if arguments.include?('update') || (arguments.include?('install') && hint == 'Available versions')
          success.with(stderr: diagnostic, exit_status: 100)
        elsif arguments.first == 'apt-cache'
          success.with(stdout: 'puppet-agent | 8.10.0-1noble | example')
        else
          method.call(arguments)
        end
      end
      expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
        .to raise_error(Empeira::Error) do |error|
          expect(error.message).to include(hint)
          expect(error.message).to include('8.10.0-1noble') if hint == 'Available versions'
        end
    end
  end
end

RSpec.describe Empeira::Node::DnfAgentRepository do
  let(:source) do
    { 'url' => 'https://packages.example.net/puppet/el/9/$basearch', 'suffix' => '-1.el9',
      'key' => { 'url' => 'https://packages.example.net/key.gpg', 'sha256' => 'a' * 64 } }
  end
  let(:files) { {} }
  let(:release_installed) { [] }
  let(:calls) { [] }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      case arguments.first
      when 'sha256sum' then success.with(stdout: "#{'a' * 64}  key.gpg\n")
      when 'cat' then success.with(stdout: "[main]\ngpgcheck=1\n")
      when 'rpm'
        release_installed << 'agent-release' if arguments.include?('-i')
        release_installed.clear if arguments.include?('-e')
        success.with(stdout: arguments.include?('-qa') ? release_installed.join("\n") : '8.12.0-1.el9')
      when 'rm'
        arguments.each { |path| files.delete(path) }
        success
      else success
      end
    end
  end
  let(:copy) { ->(path, destination, mode) { files[destination] = [File.read(path), mode] } }
  let(:installer) do
    described_class.new(source: source, package: 'puppet-agent', version: '8.12.0',
                        execute: execute, copy: copy)
  end

  around do |example|
    previous = ENV.to_h
    ENV.delete('EMPEIRA_AGENT_REPO_USERNAME')
    ENV.delete('EMPEIRA_AGENT_REPO_PASSWORD')
    example.run
  ensure
    ENV.replace(previous)
  end

  it 'installs the exact signed package from an unauthenticated DNF repository and cleans up' do
    installer.install(proxy_url: 'http://bootstrap:synthetic@proxy.example.net:3128')
    expect(calls).to include(['dnf', "--config=#{described_class::CONFIG_PATH}",
                              'install', '--assumeyes', 'puppet-agent-8.12.0-1.el9'])
    # rubocop:disable-next Style/FormatStringToken -- This is rpm queryformat syntax.
    expect(calls).to include(['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}', 'puppet-agent'])
    expect(files).not_to have_key(described_class::REPO_PATH)
    expect(files).not_to have_key(described_class::CONFIG_PATH)
    expect(calls.flatten.join(' ')).not_to include('synthetic')
  end

  it 'keeps repository credentials only in the temporary 0600 DNF source' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    captured = nil
    allow(copy).to receive(:call).and_wrap_original do |method, path, destination, mode|
      method.call(path, destination, mode)
      captured = files.fetch(destination) if destination == described_class::REPO_PATH
    end
    installer.install(proxy_url: 'http://proxy.example.net:3128')
    expect(captured.last).to eq('0600')
    expect(captured.first).to include("username=fixture-user\npassword=synthetic-secret\n")
    expect(captured.first).to include('gpgcheck=1', 'gpgkey=file://')
    expect(files).not_to have_key(described_class::REPO_PATH)
    expect(calls.flatten.join(' ')).not_to include('synthetic-secret')
  end

  it 'removes a verified DNF release package and its temporary repository files' do
    source.replace('url' => 'https://packages.example.net/agent-release-el9.rpm',
                   'sha256' => 'a' * 64, 'suffix' => '-1.el9', 'destinations' => ['packages.example.net'])
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      if arguments.first == 'rpm' && arguments.include?('-qp')
        success.with(stdout: 'agent-release')
      else
        method.call(arguments)
      end
    end
    installer.install(proxy_url: 'http://proxy.example.net:3128')
    expect(calls).to include(['rpm', '-i', '/var/tmp/empeira-agent-release.rpm'],
                             ['rpm', '-e', '--', 'agent-release'])
    expect(files).not_to have_key(described_class::CONFIG_PATH)
    expect(files).not_to have_key(described_class::CURL_CONFIG_PATH)
  end

  it 'removes the DNF source after authentication failure without leaking credentials' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      if arguments.first == 'dnf' && arguments.include?('makecache')
        success.with(stderr: '401 Unauthorized synthetic-secret', exit_status: 1)
      else
        method.call(arguments)
      end
    end
    expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
      .to raise_error(Empeira::Error, /authentication failed/) do |error|
        expect(error.message).not_to include('synthetic-secret')
      end
    expect(files).not_to have_key(described_class::REPO_PATH)
  end

  it 'rejects an installed version different from the requested RPM release' do
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      arguments.first == 'rpm' ? success.with(stdout: '8.11.0-1.el9') : method.call(arguments)
    end
    expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
      .to raise_error(Empeira::Error, /differs from the requested/)
    expect(files).not_to have_key(described_class::REPO_PATH)
  end

  { '403 Forbidden' => 'access denied', '404 Not Found' => 'unavailable',
    'GPG check FAILED' => 'signature verification failed',
    'SSL certificate problem' => 'SSL certificate problem',
    'No match for argument: puppet-agent-8.12.0-1.el9' => 'Available versions' }.each do |diagnostic, hint|
    it "diagnoses a DNF #{diagnostic} failure and removes temporary files" do
      allow(execute).to receive(:call).and_wrap_original do |method, arguments|
        if arguments.first == 'dnf' && arguments.include?('makecache')
          success.with(stderr: diagnostic, exit_status: 1)
        elsif arguments.first == 'dnf' && arguments.include?('list')
          success.with(stdout: "puppet-agent.x86_64  8.11.0-1.el9  empeira-agent\n")
        else
          method.call(arguments)
        end
      end
      expect { installer.install(proxy_url: 'http://proxy.example.net:3128') }
        .to raise_error(Empeira::Error, /#{Regexp.escape(hint)}/)
      expect(files).not_to have_key(described_class::REPO_PATH)
    end
  end
end

RSpec.describe Empeira::Node::AgentPackage do
  let(:files) { {} }
  let(:release_installed) { [] }
  let(:calls) { [] }
  let(:source) { { 'url' => 'https://packages.example.net/agent.deb', 'sha256' => 'a' * 64 } }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:execute) do
    lambda do |arguments|
      calls << arguments
      case arguments.first
      when 'sha256sum' then success.with(stdout: "#{source.fetch('sha256')}  package\n")
      when 'dpkg-query' then success.with(stdout: '8.20.0-1noble')
      when 'rpm' then success.with(stdout: '8.20.0-1.el9')
      when 'cat' then success.with(stdout: "[main]\ngpgcheck=1\n")
      when 'rm'
        arguments.each { |path| files.delete(path) }
        success
      else success
      end
    end
  end
  let(:copy) { ->(path, destination, mode) { files[destination] = [File.read(path), mode] } }

  around do |example|
    previous = ENV.to_h
    ENV.delete('EMPEIRA_AGENT_REPO_USERNAME')
    ENV.delete('EMPEIRA_AGENT_REPO_PASSWORD')
    example.run
  ensure
    ENV.replace(previous)
  end

  it 'verifies and installs an exact DEB through APT with base repository proxy' do
    installer = described_class.new(os: 'ubuntu', source: source, package: 'puppet-agent',
                                    version: '8.20.0-1noble', execute: execute, copy: copy)
    installer.install(proxy_url: 'http://bootstrap.example.net:3128')
    expect(calls).to include(array_including('apt-get', 'install', '/var/tmp/empeira-agent-package.deb'))
    expect(calls.flatten.join(' ')).not_to include('http://bootstrap.example.net:3128')
    expect(files).not_to have_key(Empeira::Node::PackageProxy::APT_PATH)
    expect(files).not_to have_key(described_class::CURL_CONFIG_PATH)
  end

  it 'verifies and installs an exact RPM with local package signature checks' do
    source['url'] = 'https://packages.example.net/agent.rpm'
    installer = described_class.new(os: 'rocky', source: source, package: 'puppet-agent',
                                    version: '8.20.0-1.el9', execute: execute, copy: copy)
    installer.install(proxy_url: 'http://bootstrap.example.net:3128')
    expect(calls).to include(array_including('dnf', '--setopt=localpkg_gpgcheck=1',
                                             '/var/tmp/empeira-agent-package.rpm'))
  end

  it 'rejects a checksum mismatch before invoking the package manager' do
    source['sha256'] = 'b' * 64
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      arguments.first == 'sha256sum' ? success.with(stdout: "#{'a' * 64}  package\n") : method.call(arguments)
    end
    installer = described_class.new(os: 'ubuntu', source: source, package: 'puppet-agent',
                                    version: '8.20.0-1noble', execute: execute, copy: copy)
    expect { installer.install(proxy_url: 'http://bootstrap.example.net:3128') }
      .to raise_error(Empeira::Error, /checksum mismatch/)
    expect(calls.flatten).not_to include('apt-get')
  end

  it 'rejects a direct artifact with the wrong installed version and removes all temporary files' do
    installer = described_class.new(os: 'ubuntu', source: source, package: 'puppet-agent',
                                    version: '9.0.0-1noble', execute: execute, copy: copy)
    expect { installer.install(proxy_url: 'http://bootstrap:temporary-secret@proxy.test:3128') }
      .to raise_error(Empeira::Error, /version differs/)
    expect(files).to be_empty
    expect(calls.flatten.join(' ')).not_to include('temporary-secret')
  end

  it 'keeps optional credentials in a temporary 0600 file and disables redirects' do
    ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'fixture-user'
    ENV['EMPEIRA_AGENT_REPO_PASSWORD'] = 'synthetic-secret'
    seen = nil
    allow(copy).to receive(:call).and_wrap_original do |method, path, destination, mode|
      method.call(path, destination, mode)
      seen = files.fetch(destination) if destination == described_class::CURL_CONFIG_PATH
    end
    installer = described_class.new(os: 'ubuntu', source: source, package: 'puppet-agent',
                                    version: '8.20.0-1noble', execute: execute, copy: copy)
    installer.install(proxy_url: 'http://bootstrap.example.net:3128')
    expect(seen).to include(a_string_including('fixture-user:synthetic-secret'), '0600')
    expect(calls.flatten).to include('--max-redirs', '0')
    expect(calls.flatten.join(' ')).not_to include('synthetic-secret')
    expect(files).not_to have_key(described_class::CURL_CONFIG_PATH)
  end
end
