# frozen_string_literal: true

RSpec.describe Empeira::Agent::Cache do
  let(:root) { Pathname(@directory).join('cache/agents') }
  let(:cache) { described_class.new(root: root) }
  let(:request) do
    { 'package' => 'synthetic-agent', 'requested_version' => '1.2.3', 'family' => 'debian',
      'distribution' => 'ubuntu', 'release' => '24.04', 'architecture' => 'amd64',
      'format' => 'deb', 'source' => 'source1' }
  end
  let(:downloads) { [] }
  let(:authorizations) { [] }

  def acquire(enabled: true, identity: request, pin: nil, failure: nil)
    fetch = ->(directory) { downloaded(directory, identity, failure) }
    cache.with_artifact(identity, enabled: enabled, pin: pin, acquire: fetch,
                                  authorize: ->(metadata) { authorizations << metadata }) do |artifact|
      expect(artifact.path).to be_file
      yield(artifact) if block_given?
      artifact.path
    end
  end

  def downloaded(directory, identity, failure)
    downloads << identity
    path = Pathname(directory).join("package.#{identity.fetch('format')}")
    content = identity.fetch('format') == 'deb' ? "!<arch>\nsynthetic-package" : "\xed\xab\xee\xdbsynthetic".b
    File.binwrite(path, content, perm: 0o600)
    raise failure if failure

    metadata = { 'schema' => 1, 'request' => identity, 'version' => '1.2.3-1',
                 'size' => content.bytesize, 'sha256' => Digest::SHA256.hexdigest(content),
                 'authenticated' => false, 'verify_signatures' => true, 'public_keys' => [],
                 'architecture' => native_architecture(identity), 'url' => 'https://packages.example.org/agent.deb' }
    Empeira::Agent::Artifact.new(path: path, metadata: metadata)
  end

  def native_architecture(identity)
    Empeira::Agent::Target.new(os: identity.fetch('distribution'), release: identity.fetch('release'),
                               architecture: identity.fetch('architecture')).native_architecture
  end

  it 'downloads once and shares the validated native artifact across independent cache clients' do
    first = acquire
    other = described_class.new(root: root)
    other.with_artifact(request, enabled: true, acquire: ->(_) { raise 'unexpected second download' },
                                 authorize: ->(_) {}) do |artifact|
      expect(artifact.path).to eq(first)
      expect(artifact.metadata.fetch('version')).to eq('1.2.3-1')
    end
    expect(downloads.size).to eq(1)
    expect(root.glob('entries/*/metadata.json').size).to eq(1)
  end

  it 'validates configured pins on hits and rejects a wrong pin on reacquisition' do
    path = acquire
    pin = Digest::SHA256.file(path).hexdigest
    acquire(pin: pin)
    expect(downloads.size).to eq(1)
    expect { acquire(pin: 'a' * 64) }.to raise_error(Empeira::Error, /damaged/)
  end

  it 'reacquires corrupted owned artifacts and does not use partial downloads' do
    path = acquire
    File.binwrite(path, 'broken')
    acquire
    expect(downloads.size).to eq(2)
    expect(root.glob('entries/.download-*')).to be_empty
    expect { acquire(identity: request.merge('source' => 'new'), failure: Interrupt.new) }.to raise_error(Interrupt)
    expect(root.glob('entries/.download-*')).to be_empty
  end

  it 'does not touch persistent entries when disabled and removes temporary artifacts after use' do
    stored = acquire
    temporary = acquire(enabled: false)
    expect(temporary).not_to exist
    expect(stored).to exist
    expect(downloads.size).to eq(2)
  end

  %w[source architecture release requested_version].each do |field|
    it "separates #{field} identities" do
      acquire
      replacement = { 'requested_version' => '1.2.3-1', 'architecture' => 'arm64',
                      'distribution' => 'ubuntu', 'release' => '22.04' }.fetch(field, 'different')
      acquire(identity: request.merge(field => replacement))
      expect(downloads.size).to eq(2)
    end
  end

  it 'requires authorization before returning an authenticated cache hit' do
    acquire
    reject = ->(_) { raise Empeira::Error, 'access denied' }
    expect do
      cache.with_artifact(request, enabled: true, acquire: ->(_) { raise 'unexpected download' },
                                   authorize: reject) { raise 'must not expose cached package' }
    end.to raise_error(Empeira::Error, /access denied/)
    expect(downloads.size).to eq(1)
  end

  it 'rejects symlinks and insecure foreign entries rather than adopting or deleting them' do
    acquire
    entry = root.glob('entries/*/package.deb').first
    entry.chmod(0o644)
    expect { acquire }.to raise_error(Empeira::Error, /unsafe or foreign/)
    expect(entry).to exist
  end

  it 'separates distribution, family, native architecture and package format' do
    deb = acquire
    rpm_identity = request.merge('family' => 'redhat', 'distribution' => 'rocky', 'release' => '9', 'format' => 'rpm')
    rpm = acquire(identity: rpm_identity)
    other = acquire(identity: rpm_identity.merge('distribution' => 'almalinux', 'architecture' => 'arm64'))
    expect([deb, rpm, other].uniq.size).to eq(3)
    expect(downloads.size).to eq(3)
  end

  it 'rejects corrupted metadata and reacquires before exposing an artifact' do
    acquire
    metadata = root.glob('entries/*/metadata.json').first
    content = JSON.parse(metadata.read).merge('public_keys' => ['invalid-base64!'])
    metadata.write(JSON.generate(content))
    acquire
    expect(downloads.size).to eq(2)
  end

  it 'reacquires structurally invalid JSON references and metadata' do
    acquire
    reference = root.glob('refs/*.json').first
    reference.write('null')
    acquire
    metadata = root.glob('entries/*/metadata.json').first
    metadata.write(JSON.generate(JSON.parse(metadata.read).merge('url' => nil)))
    acquire
    expect(downloads.size).to eq(3)
  end

  it 'rejects symlink entries without touching their target' do
    path = acquire
    external = Pathname(@directory).join('foreign.deb')
    File.rename(path, external)
    File.symlink(external, path)
    expect { acquire }.to raise_error(Empeira::Error, /unsafe or foreign/)
    expect(external).to exist
    expect(path).to be_symlink
  end

  it 'reports unavailable write permissions without yielding an installation artifact' do
    allow(Dir).to receive(:mkdir).and_call_original
    allow(Dir).to receive(:mkdir).with(root, 0o700).and_raise(Errno::EACCES)
    expect { acquire }.to raise_error(Empeira::Error, /ownership and permissions/)
    expect(downloads).to be_empty
  end

  it 'serializes concurrent cache misses and publishes one complete artifact' do
    threads = 4.times.map do
      Thread.new { acquire }
    end
    threads.each(&:value)
    expect(downloads.size).to eq(1)
    expect(root.glob('entries/*/metadata.json').size).to eq(1)
  end
end
