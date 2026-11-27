# frozen_string_literal: true

require 'spec_helper'
require 'rubygems'

RSpec.describe 'Ruby compatibility contract', :files_only do
  it 'allows Ruby 3.2 through Ruby 4.0 and rejects Ruby 3.1 in the published gem metadata' do
    gemspec = Gem::Specification.load(File.expand_path('../empeira.gemspec', __dir__))
    expect(gemspec).not_to be_nil
    %w[3.2.0 3.3.0 3.4.0 4.0.0].each do |version|
      expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new(version))).to be(true)
    end
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new('3.1.9'))).to be(false)
  end

  it 'keeps module-helper dependencies out of the CLI test bundle' do
    lock = File.read(File.expand_path('../Gemfile.lock', __dir__))
    dependencies = Bundler::LockfileParser.new(lock).specs.map(&:name)
    expect(dependencies).not_to include('r10k', 'fast_gettext', 'multi_json')
  end

  it 'retains registry checksums in both independent dependency resolutions' do
    %w[Gemfile.lock resources/modules/Gemfile.lock].each do |relative_path|
      lock = File.read(File.expand_path("../#{relative_path}", __dir__))
      expect(Bundler::LockfileParser.new(lock).bundler_version).to eq(Gem::Version.new('2.6.9'))
      checksums = lock.split("CHECKSUMS\n", 2).last.to_s.split("\n\n", 2).first.to_s
      gems = Bundler::LockfileParser.new(lock).specs.reject { |spec| spec.source.is_a?(Bundler::Source::Path) }
      gems.each do |spec|
        identity = Regexp.escape("#{spec.name} (#{spec.version})")
        expect(checksums).to match(/^  #{identity} sha256=[a-f0-9]{64}$/)
      end
    end
  end

  it 'preserves immutable native Data records' do
    record_type = Data.define(:name, :status)
    record = record_type.new(name: 'fixture', status: :running)
    expect(record.to_h).to eq(name: 'fixture', status: :running)
    expect(record).to be_frozen
    expect(record.dup).to be_frozen
    expect(record.with(status: :stopped)).to eq(record_type.new(name: 'fixture', status: :stopped))
    expect(record).not_to respond_to(:status=)
    expect { record.instance_variable_set(:@status, :stopped) }.to raise_error(FrozenError)
    expect { record_type.new(name: 'fixture') }.to raise_error(ArgumentError)

    validated = Data.define(:name) do
      def initialize(name:)
        super(name: name.dup.freeze)
      end
    end
    expect(validated.new(name: 'custom')).to be_frozen
    expect(validated.new('custom')).to eq(validated.new(name: 'custom'))
    expect(validated['custom']).to eq(validated.new(name: 'custom'))
    [nil, false, 'fixture'].each do |value|
      expect { record_type.new(value, status: :running) }.to raise_error(ArgumentError)
    end
    expect(Empeira::Providers::Resource.new('fixture', 'owner', :running))
      .to eq(Empeira::Providers::Resource.new(name: 'fixture', owner: 'owner', state: :running))
  end

  it 'freezes the memberless network policy even on Ruby 3.2' do
    policy = Empeira::Network::Policy.new
    expect(policy).to be_frozen
    expect(policy.to_h).to eq({})
    expect(policy).to eq(Empeira::Network::Policy.new)
    expect(policy.hash).to eq(Empeira::Network::Policy.new.hash)
    expect(policy.deconstruct).to eq([])
    expect { policy.instance_variable_set(:@isolated, false) }.to raise_error(FrozenError)
  end
end
