# frozen_string_literal: true

require_relative '../script/release_support'

RSpec.describe ReleaseSupport do
  it 'requires canonical version syntax and a matching release channel' do
    %w[alpha beta rc].each do |channel|
      expect(described_class.validate!("v1.2.3-#{channel}.1", channel).version).to eq("1.2.3-#{channel}.1")
    end
    expect(described_class.validate!('v1.2.3', 'stable').gem_version).to eq('1.2.3')
    [['1.2.3', 'stable'], ['v01.2.3', 'stable'], ['v1.2.3-alpha.01', 'alpha'],
     ['v1.2.3', 'alpha'], ['v1.2.3-rc.1', 'stable'], ['v1.2.3', 'unknown'],
     ["v1.2.3\n", 'stable'], ['v1.2.3;echo injected', 'stable']].each do |tag, channel|
      expect { described_class.validate!(tag, channel) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects release assets containing credentials, third-party packages or unexpected files' do
    %w[resources/agent.rpm resources/agent.deb resources/disk.qcow2 resources/key.pem
       resources/credentials/token resources/../private.txt .env .git/config vendor/tool lib/build.txt].each do |path|
      expect { described_class.validate_contents!([path]) }.to raise_error(ArgumentError)
    end
  end

  describe 'existing GitHub objects' do
    let(:tag) { 'v1.2.3-alpha.1' }
    let(:refs) { [{ 'ref' => "refs/tags/#{tag}" }] }

    it 'distinguishes a tag without a visible release from an existing release' do
      expect do
        described_class.check_available!(tag: tag, refs: refs, releases: [])
      end.to raise_error(ArgumentError, /Tag already exists without a visible GitHub release/)
    end

    it 'reports a draft or published release before its associated tag' do
      [true, false].each do |draft|
        release = { 'tag_name' => tag, 'draft' => draft }
        state = draft ? 'draft' : 'published'
        expect do
          described_class.check_available!(tag: tag, refs: refs, releases: [release])
        end.to raise_error(ArgumentError, /GitHub release already exists \(#{state}\)/)
      end
    end

    it 'permits a new version without mistaking a longer tag prefix for an exact match' do
      expect do
        described_class.check_available!(tag: tag, refs: [{ 'ref' => "refs/tags/#{tag}0" }],
                                         releases: [{ 'tag_name' => "#{tag}0", 'draft' => false }])
      end.not_to raise_error
    end
  end

  describe 'remote publication verification' do
    let(:artifact) { File.join(@directory, 'empeira-1.2.3.pre.alpha.1.gem') }
    let(:tag) { 'v1.2.3-alpha.1' }
    let(:revision) { 'a' * 40 }
    let(:ref) { { 'ref' => "refs/tags/#{tag}", 'object' => { 'type' => 'commit', 'sha' => revision } } }
    let(:asset) do
      { 'name' => File.basename(artifact), 'state' => 'uploaded', 'size' => File.size(artifact),
        'digest' => "sha256:#{Digest::SHA256.file(artifact).hexdigest}" }
    end
    let(:release) do
      { 'tag_name' => tag, 'draft' => false, 'prerelease' => true, 'published_at' => '2026-01-01T00:00:00Z',
        'immutable' => true, 'assets' => [asset] }
    end

    before { File.write(artifact, 'synthetic release artifact') }

    it 'accepts a complete draft before publication and a complete immutable published release' do
      verify_remote(release.merge('draft' => true, 'published_at' => nil, 'immutable' => false), draft: true)
      verify_remote(release)
    end

    it 'rejects a missing release instead of treating a retained tag as success' do
      expect { verify_remote(nil) }.to raise_error(ArgumentError, /Expected exactly one GitHub release/)
    end

    it 'rejects a draft, absent publication time or wrong prerelease channel after publication' do
      [{ 'draft' => true }, { 'published_at' => nil }, { 'prerelease' => false }].each do |change|
        expect { verify_remote(release.merge(change)) }.to raise_error(ArgumentError, /publication state/)
      end
    end

    it 'rejects a tag pointing to a different commit or an unexpected reference' do
      ref['object']['sha'] = 'b' * 40
      expect { verify_remote(release) }.to raise_error(ArgumentError, /tested revision/)
      ref['object']['sha'] = revision
      ref['ref'] = "refs/tags/#{tag}0"
      expect { verify_remote(release) }.to raise_error(ArgumentError, /tested revision/)
    end

    it 'rejects absent, duplicate, partial or changed assets even on an immutable release' do
      changes = [{ 'name' => 'other.gem' }, { 'state' => 'starter' }, { 'size' => 0 },
                 { 'digest' => nil }, { 'digest' => "sha256:#{'b' * 64}" }]
      assets = [[], [asset, asset]] + changes.map { |change| [asset.merge(change)] }
      assets.each do |entries|
        expect { verify_remote(release.merge('assets' => entries)) }.to raise_error(ArgumentError, /asset/)
      end
    end

    def verify_remote(entry, draft: false)
      described_class.verify_github_release!(releases: [entry].compact, ref: ref, artifact: artifact,
                                             tag: tag, revision: revision, draft: draft)
    end
  end

  it 'builds and installs a metadata-consistent prerelease without changing source metadata' do
    metadata = Empeira::BuildInfo::METADATA_PATH
    original = File.binread(metadata) if File.exist?(metadata)
    inputs = { tag: 'v1.2.3-alpha.1', channel: 'alpha', revision: 'a' * 40, build_time: '2026-01-01T00:00:00Z' }
    path = described_class.build!(**inputs, output: File.join(@directory, 'pkg'))
    expect(Empeira::BuildInfo::METADATA_PATH).to eq(metadata)
    expect(File.basename(path)).to eq('empeira-1.2.3.pre.alpha.1.gem')
    expect(described_class.verify!(path, **inputs)).to eq(Digest::SHA256.file(path).hexdigest)
    expect do
      described_class.verify!(path, **inputs, revision: 'b' * 40)
    end.to raise_error(ArgumentError, /BuildInfo/)
    expect do
      described_class.verify!(path, **inputs, tag: 'v1.2.4-alpha.1')
    end.to raise_error(ArgumentError, /version/)
    expect(File.exist?(metadata) ? File.binread(metadata) : nil).to eq(original)
    expect(Gem::Package.new(path).spec.runtime_dependencies.map(&:name)).to eq(['thor'])
    Bundler.with_unbundled_env { verify_installed_cli(path) }
  end

  it 'rejects workflow dispatch from any branch other than main without building or publishing' do
    runner = Empeira::Execution::Runner.new
    result = runner.run(RbConfig.ruby, arguments: [File.join(described_class::ROOT, 'script/release.rb'), 'validate'],
                                       environment: { 'EMPEIRA_BUILD_VERSION' => 'v1.2.3',
                                                      'EMPEIRA_RELEASE_CHANNEL' => 'stable',
                                                      'GITHUB_REF' => 'refs/heads/initial' })
    expect(result).not_to be_success
    expect(result.stderr).to include('must be dispatched from main')
  end

  # rubocop:disable-next Metrics/AbcSize -- Exercise installation and actual CLI metadata in an isolated gem home.
  def verify_installed_cli(path)
    directory = File.join(@directory, 'installed')
    runner = Empeira::Execution::Runner.new
    environment = { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLE_GEMFILE' => nil, 'BUNDLE_BIN_PATH' => nil,
                    'GEM_HOME' => directory, 'GEM_PATH' => ([directory] + Gem.path).uniq.join(File::PATH_SEPARATOR) }
    result = runner.run(RbConfig.ruby, arguments: ['-S', 'gem', 'install', '--local', '--ignore-dependencies',
                                                   '--no-document', '--install-dir', directory, path],
                                       environment: environment, timeout: 30)
    expect(result).to be_success
    installed_metadata = File.join(directory, 'gems/empeira-1.2.3.pre.alpha.1/lib/empeira/build.json')
    expect(File.read(installed_metadata)).to include('1.2.3-alpha.1')
    result = runner.run(RbConfig.ruby, arguments: [File.join(directory, 'bin/empeira'), 'version', '--verbose'],
                                       environment: environment)
    expect(result).to be_success
    expect(result.stdout).to include('1.2.3-alpha.1', 'a' * 40, '2026-01-01T00:00:00Z')
  end
end
