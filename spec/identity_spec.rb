# frozen_string_literal: true

RSpec.describe 'Workspace and image identities' do
  it 'keeps one checkout stable while distinguishing users and checkouts' do
    other = File.join(@directory, 'other')
    initialize_project(other)
    identity = Empeira::Workspace.new(path: @directory, user_home: @directory)
    expect(identity.id).to eq(Empeira::Workspace.new(path: File.join(@directory, '.'), user_home: @directory).id)
    expect(identity.id).not_to eq(Empeira::Workspace.new(path: other, user_home: @directory).id)
    expect(identity.id).not_to eq(Empeira::Workspace.new(path: @directory, user_home: other).id)
    expect(identity.id).to match(/\A[0-9a-f]{24}\z/)
  end

  it 'resolves checkout symlinks to the same workspace' do
    link = File.join(@directory, 'alias')
    checkout = File.join(@directory, 'checkout')
    initialize_project(checkout)
    File.symlink(checkout, link)
    expect(Empeira::Workspace.new(path: link).id).to eq(Empeira::Workspace.new(path: checkout).id)
  end

  it 'includes every image revision field and checksum in a path-safe cache key' do
    fields = { distribution: 'debian', version: '12', architecture: 'amd64', source: 'https://example.invalid/base',
               revision: '2026-01-01', checksum: 'a' * 64 }
    original = Empeira::Images::Identity.new(**fields)
    fields.each_key do |key|
      changed = key == :checksum ? 'b' * 64 : "different-#{fields[key]}"
      expect(Empeira::Images::Identity.new(**fields, key => changed).cache_key).not_to eq(original.cache_key)
    end
    expect(original.cache_key).to match(/\A[0-9a-f]{64}\z/)
    locations = Empeira::Platform::Locations.new(home: @directory, environment: {})
    expect(locations.image(original)).to eq(locations.cache.join('images', original.cache_key))
  end

  it 'rejects images without an integrity checksum' do
    expect do
      Empeira::Images::Identity.new(distribution: 'debian', version: '12', architecture: 'amd64',
                                    source: 'upstream', revision: '1', checksum: 'invalid')
    end.to raise_error(Empeira::Error, /SHA-256/)
  end
end
