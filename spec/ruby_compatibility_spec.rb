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
      expect(lock).to include('fast_gettext (3.1.0)')
      expect(lock).to include('multi_json (1.18.0)')
      expect(Bundler::LockfileParser.new(lock).bundler_version).to eq(Gem::Version.new('2.6.9'))
      expect(lock).not_to include('fast_gettext (4.')
      checksums = lock.split("CHECKSUMS\n", 2).last.to_s.split("\n\n", 2).first.to_s
      gems = Bundler::LockfileParser.new(lock).specs.reject { |spec| spec.source.is_a?(Bundler::Source::Path) }
      gems.each do |spec|
        identity = Regexp.escape("#{spec.name} (#{spec.version})")
        expect(checksums).to match(/^  #{identity} sha256=[a-f0-9]{64}$/)
      end
    end
  end

  it 'preserves immutable Data-style records on Ruby 3.1' do
    record_type = Empeira::Compatibility::DataFactory.define(:name, :status)
    record = record_type.new(name: 'fixture', status: :running)
    expect(record.to_h).to eq(name: 'fixture', status: :running)
    expect(record).to be_frozen
    expect(record.dup).to be_frozen
    expect(record.with(status: :stopped)).to eq(record_type.new(name: 'fixture', status: :stopped))
    expect { record.status = :stopped }.to raise_error(FrozenError)
    expect { record_type.new(name: 'fixture') }.to raise_error(ArgumentError)

    validated = Empeira::Compatibility::DataFactory.define(:name) do
      def initialize(name:)
        super(name: name.dup.freeze)
      end
    end
    expect(validated.new(name: 'custom')).to be_frozen

    empty = Empeira::Compatibility::DataFactory.define
    expect(empty.new).to be_frozen
    expect(empty.new.to_h).to eq({})
    expect(empty.new).to eq(empty.new)
    expect(empty.new.hash).to eq(empty.new.hash)
    expect(empty.new.deconstruct).to eq([])
  end
end
