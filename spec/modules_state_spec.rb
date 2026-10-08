# frozen_string_literal: true

RSpec.describe Empeira::Modules::State do
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
  let(:context) { Empeira::Application.new(project_path: @directory, locations: locations).context }
  let(:state) { described_class.new(context: context) }
  let(:root) { Pathname(@directory).join('modules') }

  it 'stores installed names outside modules and checks shallow presence without hashing content' do
    state.prepare
    root.join('sample').mkpath
    root.join('sample/value').write('installed')
    state.record(root, ['sample'])
    expect(state.available?(root)).to be(true)
    root.join('sample/value').write('live user change')
    expect(state.available?(root)).to be(true)
    expect(root.children.map { |entry| entry.basename.to_s }).to eq(['sample'])
    FileUtils.remove_entry(root.join('sample'))
    expect(state.available?(root)).to be(false)
  end

  it 'invalidates installed names before a potentially partial update' do
    state.prepare
    root.mkpath
    state.record(root, [])
    expect(state.available?(root)).to be(true)
    state.invalidate
    expect(state.available?(root)).to be(false)
  end

  it 'requires the module root even for an empty Puppetfile' do
    state.prepare
    state.record(root, [])
    expect(state.available?(root)).to be(false)
  end

  it 'accepts manually installed modules without metadata or any fingerprint' do
    root.join('sample').mkpath
    root.join('sample/metadata.json').write('{}')
    expect(state.available?(root)).to be(true)
  end

  it 'requires an installed fallback when an optional local override disappears' do
    state.prepare
    root.join('hieradata').mkpath
    state.record(root, ['hieradata'])
    expect(state.available?(root, overrides: ['hieradata'])).to be(true)
    expect(state.available?(root)).to be(false)
    root.join('hieradata/hiera.yaml').write('version: 5')
    expect(state.available?(root)).to be(true)
  end

  it 'rejects symlinked tooling caches' do
    state.sources.parent.mkpath
    File.symlink(@directory, state.sources)
    expect { state.prepare }.to raise_error(Empeira::Error, /symlink/)
  end
end
