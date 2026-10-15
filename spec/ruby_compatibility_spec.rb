# frozen_string_literal: true

require 'spec_helper'
require 'rubygems'

RSpec.describe 'Ruby compatibility contract' do
  it 'allows Ruby 3.1 through Ruby 4.0 in the published gem metadata' do
    gemspec = Gem::Specification.load(File.expand_path('../empeira.gemspec', __dir__))
    expect(gemspec).not_to be_nil
    %w[3.1.0 3.2.0 3.3.0 3.4.0 4.0.0].each do |version|
      expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new(version))).to be(true)
    end
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new('3.0.0'))).to be(false)
  end

  it 'uses a Bundler and r10k dependency resolution compatible with Ruby 3.1' do
    %w[Gemfile.lock resources/modules/Gemfile.lock].each do |relative_path|
      lock = File.read(File.expand_path("../#{relative_path}", __dir__))
      expect(lock).to include("fast_gettext (3.1.0)")
      expect(lock).to include("multi_json (1.18.0)")
      expect(lock).to include("BUNDLED WITH\n  2.6.9")
      expect(lock).not_to include('fast_gettext (4.')
    end
  end
end
