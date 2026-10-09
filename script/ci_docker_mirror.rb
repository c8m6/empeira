# frozen_string_literal: true

require 'json'

# Hosted smoke-runner setup; excluded from the installed application.
module CIDockerMirror
  MIRROR = 'https://mirror.gcr.io'

  def self.configuration(contents)
    config = JSON.parse(contents)
    raise ArgumentError, 'Docker daemon configuration must be an object' unless config.is_a?(Hash)

    mirrors = config.fetch('registry-mirrors', [])
    unless mirrors.is_a?(Array) && mirrors.all?(String)
      raise ArgumentError, 'Docker registry-mirrors must be an array of strings'
    end

    JSON.pretty_generate(config.merge('registry-mirrors' => [MIRROR, *mirrors].uniq))
  end

  def self.verify!(contents)
    mirrors = JSON.parse(contents)
    return if mirrors.is_a?(Array) && mirrors.intersect?([MIRROR, "#{MIRROR}/"])

    raise ArgumentError, 'Docker did not activate the public Docker Hub cache'
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.shift
  when 'configure'
    path = ARGV.fetch(0)
    puts CIDockerMirror.configuration(File.exist?(path) ? File.read(path) : '{}')
  when 'verify'
    CIDockerMirror.verify!($stdin.read)
  else
    abort 'Usage: ci_docker_mirror.rb configure DAEMON_JSON | verify'
  end
end
