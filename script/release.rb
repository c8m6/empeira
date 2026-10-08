# frozen_string_literal: true

require 'time'
require_relative 'release_support'

# No tags, network requests, source metadata or releases are written by this script.
tag = ENV.fetch('EMPEIRA_BUILD_VERSION')
channel = ENV.fetch('EMPEIRA_RELEASE_CHANNEL')
case ARGV.fetch(0, 'validate')
when 'validate'
  ReleaseSupport.validate!(tag, channel)
  abort 'Release workflows must be dispatched from main' unless ENV.fetch('GITHUB_REF') == 'refs/heads/main'
when 'check-available'
  ReleaseSupport.validate!(tag, channel)
  ReleaseSupport.check_available!(tag: tag, refs: JSON.parse(File.read(ARGV.fetch(1))).flatten(1),
                                  releases: JSON.parse(File.read(ARGV.fetch(2))).flatten(1))
when 'build'
  path = ReleaseSupport.build!(tag: tag, channel: channel, revision: ENV.fetch('EMPEIRA_BUILD_REVISION'),
                               build_time: ENV.fetch('EMPEIRA_BUILD_TIME'),
                               output: File.join(ReleaseSupport::ROOT, 'pkg'))
  puts "Verified release gem: #{File.basename(path)}"
when 'verify'
  gems = Dir[File.join(ReleaseSupport::ROOT, 'pkg/*.gem')]
  abort 'Expected exactly one release gem' unless gems.size == 1
  digest = ReleaseSupport.verify!(gems.first, tag: tag, channel: channel, revision: ENV.fetch('EMPEIRA_BUILD_REVISION'),
                                              build_time: ENV.fetch('EMPEIRA_BUILD_TIME'))
  abort 'Release gem checksum changed' unless digest == ENV.fetch('EMPEIRA_ARTIFACT_SHA256')
when 'verify-draft', 'verify-published'
  ReleaseSupport.validate!(tag, channel)
  gems = Dir[File.join(ReleaseSupport::ROOT, 'pkg/*.gem')]
  abort 'Expected exactly one release gem' unless gems.one?
  ReleaseSupport.verify_github_release!(releases: JSON.parse(File.read(ARGV.fetch(1))).flatten(1),
                                        ref: JSON.parse(File.read(ARGV.fetch(2))), artifact: gems.first,
                                        tag: tag, revision: ENV.fetch('EMPEIRA_BUILD_REVISION'),
                                        draft: ARGV.first == 'verify-draft')
else
  abort 'Usage: ruby script/release.rb validate|check-available|build|verify|verify-draft|verify-published'
end
