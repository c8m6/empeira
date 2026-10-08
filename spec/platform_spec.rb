# frozen_string_literal: true

RSpec.describe Empeira::Platform do
  [
    ['linux-gnu', 'x86_64', {}, '6.1', :linux, :amd64],
    ['darwin24', 'arm64', {}, '', :macos, :arm64],
    ['darwin', 'x86_64-darwin', {}, '', :macos, :amd64],
    ['linux', 'aarch64-linux-gnu', {}, '', :linux, :arm64],
    ['linux', 'amd64', { 'WSL_DISTRO_NAME' => 'Ubuntu' }, '', :wsl, :amd64],
    ['linux', 'x86_64', {}, '5.15-microsoft-standard-WSL2', :wsl, :amd64]
  ].each do |os, cpu, env, kernel, expected_os, expected_cpu|
    it "normalizes #{os}/#{cpu}/#{kernel}" do
      facts = described_class::Facts.new(host_os: os, host_cpu: cpu, environment: env, kernel_release: kernel)
      expect(facts.os).to eq(expected_os)
      expect(facts.architecture).to eq(expected_cpu)
      expect(facts.process_groups?).to eq(true)
    end
  end

  it 'rejects unsupported architectures' do
    expect { described_class::Facts.new(host_os: 'linux', host_cpu: 'sparc', kernel_release: '') }
      .to raise_error(Empeira::UnsupportedPlatform, /architecture/)
  end

  it 'rejects unsupported operating systems' do
    expect { described_class::Facts.new(host_os: 'unknown') }
      .to raise_error(Empeira::UnsupportedPlatform, /operating system/)
  end

  it 'honors absolute XDG directories on Linux and WSL' do
    %i[linux wsl].each do |os|
      cache = File.join(@directory, 'custom-cache')
      state = File.join(@directory, 'custom-state')
      locations = described_class::Locations.new(facts: double(os: os), home: @directory,
                                                 environment: { 'XDG_CACHE_HOME' => cache, 'XDG_STATE_HOME' => state })
      expect(locations.cache).to eq(Pathname(cache).join('empeira'))
      expect(locations.state).to eq(Pathname(state).join('empeira'))
    end
  end

  it 'ignores relative XDG directories and does not create directories just by querying' do
    locations = described_class::Locations.new(facts: double(os: :linux), home: @directory,
                                               environment: { 'XDG_CACHE_HOME' => 'relative' })
    expect(locations.cache).to eq(Pathname(@directory).join('.cache/empeira'))
    expect(locations.cache).not_to exist
  end

  it 'uses macOS Library locations' do
    locations = described_class::Locations.new(facts: double(os: :macos), home: @directory, environment: {})
    expect(locations.cache).to eq(Pathname(@directory).join('Library/Caches/empeira'))
    expect(locations.state).to eq(Pathname(@directory).join('Library/Application Support/empeira'))
  end

  it 'rejects native Windows execution' do
    %w[mingw-ucrt mswin64].each do |os|
      expect { described_class::Facts.new(host_os: os) }.to raise_error(Empeira::UnsupportedPlatform, /WSL2/)
    end
  end
end
