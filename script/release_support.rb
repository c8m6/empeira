# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'rubygems/package'
require 'tmpdir'
require 'stringio'
require 'time'
require 'zlib'
require_relative '../lib/empeira/build_info'

# Release tooling is not part of the installed application.
# rubocop:disable-next Metrics/ModuleLength -- One cohesive packaging boundary shared by build and verification.
module ReleaseSupport
  ROOT = File.expand_path('..', __dir__).freeze
  TAG = /\Av(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)\.(0|[1-9]\d*))?\z/
  ALLOWED = %r{\A(?:lib/.*\.rb|lib/empeira/build\.json|config/[^/]+\.yaml|resources/.+|
                    bin/empeira|docs/[^/]+\.md|README\.md|LICENSE)\z}x
  FORBIDDEN = %r{(?:\A|/)(?:\.git|\.env|vendor|tmp|pkg|credentials)(?:/|\z)|
                  \.(?:gem|deb|rpm|qcow2|iso|pem|key|crt)\z}ix

  def self.validate!(tag, channel)
    match = TAG.match(tag)
    raise ArgumentError, 'Use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-alpha|beta|rc.N' unless match
    unless %w[alpha beta rc stable].include?(channel)
      raise ArgumentError, 'Release channel must be alpha, beta, rc or stable'
    end
    unless (match[4] || 'stable') == channel
      raise ArgumentError, 'The release tag prerelease suffix must match its channel'
    end

    Empeira::BuildInfo.new(version: tag)
  end

  def self.check_available!(tag:, refs:, releases:)
    release = releases.find { |entry| entry.fetch('tag_name') == tag }
    if release
      state = release.fetch('draft') ? 'draft' : 'published'
      raise ArgumentError, "GitHub release already exists (#{state}) for #{tag}; inspect it and choose a new version"
    end
    return unless refs.any? { |entry| entry.fetch('ref') == "refs/tags/#{tag}" }

    raise ArgumentError, "Tag already exists without a visible GitHub release for #{tag}; " \
                         'inspect the failed run and any retained draft; choose a new version for another workflow run'
  end

  # rubocop:disable-next Metrics/AbcSize -- Check the remote publication boundary before freezing assets and after publishing.
  def self.verify_github_release!(releases:, ref:, artifact:, tag:, revision:, draft:)
    matches = releases.select { |entry| entry.fetch('tag_name') == tag }
    unless matches.one?
      raise ArgumentError, "Expected exactly one GitHub release for #{tag}; inspect the retained tag/draft"
    end

    release = matches.first
    unless release.fetch('draft') == draft && release.fetch('prerelease') == tag.include?('-') &&
           (draft || !release.fetch('published_at').to_s.empty?)
      raise ArgumentError, 'GitHub release publication state does not match; inspect the retained tag/release'
    end

    verify_release_ref!(ref, tag: tag, revision: revision)
    verify_release_asset!(release.fetch('assets'), artifact)
  end

  def self.verify_release_ref!(ref, tag:, revision:)
    object = ref.fetch('object')
    unless ref.fetch('ref') == "refs/tags/#{tag}" && object.fetch('type') == 'commit' && object.fetch('sha') == revision
      raise ArgumentError, 'GitHub release tag does not point to the tested revision'
    end
  end

  def self.verify_release_asset!(assets, artifact)
    expected = { 'name' => File.basename(artifact), 'state' => 'uploaded', 'size' => File.size(artifact),
                 'digest' => "sha256:#{Digest::SHA256.file(artifact).hexdigest}" }
    return if assets.one? && assets.first.slice(*expected.keys) == expected

    raise ArgumentError, 'GitHub release asset is missing, incomplete or differs from the verified gem'
  end

  # rubocop:disable-next Metrics/AbcSize -- Stage, build and verify one artifact without mutating the checkout.
  def self.build!(tag:, channel:, revision:, build_time:, output:)
    validate!(tag, channel)
    Dir.chdir(ROOT) do
      spec = Gem::Specification.load(File.join(ROOT, 'empeira.gemspec'))
      Dir.mktmpdir('empeira-release-') do |stage|
        stage_sources(spec, stage)
        generate_metadata(stage, tag: tag, revision: revision, build_time: build_time)
        name = Dir.chdir(stage) { Gem::Package.build(Gem::Specification.load(File.join(stage, 'empeira.gemspec'))) }
        verify!(File.join(stage, name), tag: tag, channel: channel, revision: revision, build_time: build_time)
        FileUtils.mkdir_p(output)
        FileUtils.cp(File.join(stage, name), output)
        File.join(output, name)
      end
    end
  end

  def self.stage_sources(spec, stage)
    (spec.files + ['empeira.gemspec']).each do |path|
      next if path == 'lib/empeira/build.json'
      next unless File.file?(path)

      raise ArgumentError, "Release source must not be a symlink: #{path}" if File.symlink?(path)

      target = File.join(stage, path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(path, target)
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Restore the invoking environment even when the shared build task fails.
  def self.generate_metadata(stage, tag:, revision:, build_time:)
    require 'rake'
    load File.join(ROOT, 'Rakefile') unless Rake::Task.task_defined?(:build_info)
    values = { 'EMPEIRA_BUILD_VERSION' => tag, 'EMPEIRA_BUILD_REVISION' => revision,
               'EMPEIRA_BUILD_TIME' => build_time }
    original = values.to_h { |key, value| [key, ENV.fetch(key, nil)].tap { ENV[key] = value } }
    Rake::Task[:build_info].reenable
    Rake::Task[:build_info].invoke(File.join(stage, 'lib/empeira/build.json'))
  ensure
    original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Inspect the complete archive before accepting a release artifact.
  def self.verify!(path, tag:, channel:, revision:, build_time:)
    info = validate!(tag, channel)
    package = Gem::Package.new(path)
    package.verify
    unless package.spec.name == 'empeira' && package.spec.version == Gem::Version.new(info.gem_version) &&
           package.spec.license == 'AGPL-3.0-only'
      raise ArgumentError, 'Gem name, version or license does not match the release'
    end

    contents = package.contents
    validate_contents!(contents)
    files = archive_files(path)
    expected = info.to_h.merge(revision: revision, build_time: Time.iso8601(build_time).utc.iso8601)
    actual = JSON.parse(files.fetch('lib/empeira/build.json'), symbolize_names: true)
    raise ArgumentError, 'Embedded BuildInfo does not match the release inputs' unless actual == expected
    unless files.key?('LICENSE') && files.key?('bin/empeira')
      raise ArgumentError, 'Release is missing its license or executable'
    end

    Digest::SHA256.file(path).hexdigest
  end

  def self.validate_contents!(contents)
    contents.each do |path|
      components = path.split('/')
      if !path.match?(ALLOWED) || components.any? { |part| part.empty? || %w[. ..].include?(part) } ||
         path.match?(FORBIDDEN)
        raise ArgumentError, "Unexpected release artifact content: #{path}"
      end
    end
  end

  def self.archive_files(path)
    files = {}
    File.open(path, 'rb') do |file|
      Gem::Package::TarReader.new(file) do |outer|
        outer.each do |entry|
          next unless entry.full_name == 'data.tar.gz'

          Zlib::GzipReader.wrap(StringIO.new(entry.read)) do |gzip|
            Gem::Package::TarReader.new(gzip) { |inner| read_entries(inner, files) }
          end
        end
      end
    end
    files
  end

  def self.read_entries(archive, files)
    archive.each do |entry|
      raise ArgumentError, 'Release archive contains a non-regular file' unless entry.file?
      raise ArgumentError, 'Release archive contains duplicate files' if files.key?(entry.full_name)

      files[entry.full_name] = entry.read
    end
  end
end
