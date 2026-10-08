# frozen_string_literal: true

require 'rake'
require 'rspec/core/rake_task'
require 'json'
require 'time'
require_relative 'lib/empeira/build_info'

RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc 'Generate build metadata from release pipeline inputs'
task :build_info, [:output] do |_task, arguments|
  version = ENV.fetch('EMPEIRA_BUILD_VERSION')
  unless version.match?(/\Av\d+\.\d+\.\d+(?:-[\w.]+)?\z/)
    abort 'EMPEIRA_BUILD_VERSION must be a release tag such as v0.3.0'
  end
  revision = ENV.fetch('EMPEIRA_BUILD_REVISION')
  abort 'EMPEIRA_BUILD_REVISION must be a full Git revision' unless revision.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
  build_time = Time.iso8601(ENV.fetch('EMPEIRA_BUILD_TIME')).utc.iso8601
  info = Empeira::BuildInfo.new(version: version, revision: revision, build_time: build_time)
  output = arguments[:output] || Empeira::BuildInfo::METADATA_PATH
  File.write(output, "#{JSON.pretty_generate(info.to_h)}\n")
end
