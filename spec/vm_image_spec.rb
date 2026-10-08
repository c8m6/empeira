# frozen_string_literal: true

require 'digest'

RSpec.describe 'Verified VM images' do
  let(:payload) { 'qcow2 test image' }
  let(:checksum) { Digest::SHA256.hexdigest(payload) }

  it 'resolves Ubuntu and Rocky images from exact upstream checksum entries' do
    source = Empeira::VM::ImageSource.new(fetch_text: lambda { |url|
      if url.end_with?('SHA256SUMS')
        "#{checksum} *ubuntu-24.04-server-cloudimg-amd64.img\n"
      else
        "SHA256 (Rocky-9-GenericCloud-Base.latest.x86_64.qcow2) = #{checksum}\n"
      end
    })
    ubuntu = source.resolve(distribution: 'ubuntu', version: '24.04', architecture: :amd64)
    rocky = source.resolve(distribution: 'rocky', version: '9', architecture: :amd64)
    expect(ubuntu.url).to eq('https://cloud-images.ubuntu.com/releases/noble/release/' \
                             'ubuntu-24.04-server-cloudimg-amd64.img')
    expect(rocky.url).to include('rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2')
    expect(ubuntu.identity.checksum).to eq(checksum)
    expect(rocky.identity.checksum).to eq(checksum)
    expect(ubuntu.identity.cache_key).not_to eq(rocky.identity.cache_key)
  end

  it 'refuses missing checksums and unsupported image families' do
    source = Empeira::VM::ImageSource.new(fetch_text: ->(_url) { "#{checksum} *other.img\n" })
    expect { source.resolve(distribution: 'ubuntu', version: '24.04', architecture: :amd64) }
      .to raise_error(Empeira::Error, /checksum/)
    expect { source.resolve(distribution: 'oraclelinux', version: '8', architecture: :amd64) }
      .to raise_error(Empeira::UnavailableFeature, /verified VM image/)
  end

  it 'caches a checksum-verified immutable base and detects corruption before reuse' do
    image = Empeira::VM::ImageSource::Image.new(
      identity: Empeira::Images::Identity.new(distribution: 'ubuntu', version: '24.04', architecture: 'amd64',
                                              source: 'https://example.invalid/image', revision: '1',
                                              checksum: checksum),
      url: 'https://example.invalid/image', filename: 'image'
    )
    locations = Empeira::Platform::Locations.new(home: @directory, environment: {})
    downloads = 0
    cache = Empeira::VM::ImageCache.new(locations: locations, downloader: lambda { |_url, file|
      downloads += 1
      file.write(payload)
    })
    path = cache.fetch(image)
    expect(File.read(path)).to eq(payload)
    expect(File.stat(path).mode & 0o222).to eq(0)
    expect(cache.fetch(image)).to eq(path)
    expect(downloads).to eq(1)
    File.chmod(0o600, path)
    File.write(path, 'corrupt')
    expect(cache.fetch(image)).to eq(path)
    expect(downloads).to eq(2)
    expect(File.read(path)).to eq(payload)
  end

  it 'never promotes an image with an incorrect checksum' do
    image = Empeira::VM::ImageSource::Image.new(
      identity: Empeira::Images::Identity.new(distribution: 'ubuntu', version: '24.04', architecture: 'amd64',
                                              source: 'https://example.invalid/image', revision: '1',
                                              checksum: checksum),
      url: 'https://example.invalid/image', filename: 'image'
    )
    locations = Empeira::Platform::Locations.new(home: @directory, environment: {})
    cache = Empeira::VM::ImageCache.new(locations: locations, downloader: lambda { |_url, file|
      file.write('wrong')
    })
    expect { cache.fetch(image) }.to raise_error(Empeira::Error, /SHA-256/)
    expect(locations.image(image.identity).join('base.qcow2')).not_to exist
  end
end
