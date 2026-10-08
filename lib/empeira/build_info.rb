# frozen_string_literal: true

require 'json'
require_relative 'version_requirement'

module Empeira
  class BuildInfo
    METADATA_PATH = File.expand_path('build.json', __dir__).freeze
    attr_reader :version, :revision, :build_time

    def self.load(path: METADATA_PATH)
      data = File.file?(path) ? JSON.parse(File.read(path)) : {}
      new(**data.transform_keys(&:to_sym))
    end

    def initialize(version: 'development', revision: nil, build_time: nil)
      @version = version.delete_prefix('v').freeze
      @revision = revision&.dup&.freeze
      @build_time = build_time&.dup&.freeze
      freeze
    end

    def gem_version
      version == 'development' ? '0.0.0.development' : version
    end

    def requirement_status(requirement)
      parsed = VersionRequirement.parse(requirement)
      return 'not required' unless parsed
      return 'unverifiable (development build)' if version == 'development'

      parsed.satisfied_by?(Gem::Version.new(version)) ? 'satisfied' : 'incompatible'
    end

    def require_compatible!(requirement)
      return if ['not required', 'satisfied'].include?(requirement_status(requirement))

      raise Error, "Empeira version requirement is not satisfied.\nRequired: #{requirement}\nInstalled: #{version}\n" \
                   "Update Empeira before modifying this project.\nRun: empeira self-update"
    end

    def to_h
      { version: version, revision: revision, build_time: build_time }
    end
  end
end
