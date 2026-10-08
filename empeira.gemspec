# frozen_string_literal: true

require_relative 'lib/empeira/build_info' unless defined?(Empeira::BuildInfo)

Gem::Specification.new do |spec|
  spec.name = 'empeira'
  spec.version = Empeira::BuildInfo.load(path: File.join(__dir__, 'lib/empeira/build.json')).gem_version
  spec.authors = ['Empeira contributors']
  spec.summary = 'Disposable Puppet/OpenVox test infrastructure'
  spec.description = 'Ephemeral Manifest Playground for Exploring Infrastructure, Roles & Automation.'
  spec.homepage = 'https://github.com/c8m6/empeira'
  spec.license = 'AGPL-3.0-only'
  spec.required_ruby_version = '>= 3.4'
  spec.files = Dir['lib/**/*.rb', 'lib/empeira/build.json', 'config/*.yaml', 'resources/**/*', 'bin/*',
                   'docs/*.md', 'README.md', 'LICENSE']
  spec.bindir = 'bin'
  spec.executables = ['empeira']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.add_dependency 'thor', '~> 1.5'
end
