# frozen_string_literal: true

RSpec.describe Empeira::BuildInfo do
  it 'uses development defaults without Git or generated metadata' do
    info = described_class.load(path: File.join(@directory, 'missing.json'))
    expect(info.to_h).to eq(version: 'development', revision: nil, build_time: nil)
    expect(info.gem_version).to eq('0.0.0.development')
  end

  it 'reads release metadata supplied by packaging' do
    path = File.join(@directory, 'build.json')
    File.write(path, JSON.generate(version: 'v0.3.0', revision: 'a' * 40, build_time: '2026-09-30T12:00:00Z'))
    info = described_class.load(path: path)
    expect(info.version).to eq('0.3.0')
    expect(info.gem_version).to eq('0.3.0')
    expect(info.revision).to eq('a' * 40)
  end
end
