# frozen_string_literal: true

RSpec.describe Empeira::Node::SSHIdentity do
  let(:home) { Pathname(@directory).join('personal home') }
  let(:key) { home.join('.ssh', 'test key') }
  let(:identity) { described_class.new(home: home) }

  before do
    key.dirname.mkpath
    key.write('synthetic private key contents')
    key.chmod(0o600)
  end

  it 'resolves ~/ through the platform home and preserves absolute paths including spaces' do
    expect(identity.resolve('~/.ssh/test key')).to eq(key.to_s)
    expect(identity.resolve(key.to_s)).to eq(key.to_s)
  end

  it 'preserves CLI relative paths relative to the invocation directory' do
    Dir.chdir(home) { expect(identity.resolve('.ssh/test key')).to eq(key.to_s) }
  end

  it 'rejects missing keys without inspecting key contents' do
    expect { identity.resolve(home.join('missing').to_s) }
      .to raise_error(Empeira::ConfigurationError, /missing or unreadable/)
  end

  it 'rejects symlinks instead of silently following them' do
    link = home.join('link')
    File.symlink(key, link)
    expect { identity.resolve(link.to_s) }.to raise_error(Empeira::ConfigurationError, /regular file.*symlink/)
  end

  it 'rejects directories and other nonregular file types' do
    expect { identity.resolve(key.dirname.to_s) }.to raise_error(Empeira::ConfigurationError, /regular file/)
  end

  [0o644, 0o640, 0o610, 0o602].each do |mode|
    it "rejects group or other access in mode #{mode.to_s(8)}" do
      key.chmod(mode)
      expect { identity.resolve(key.to_s) }.to raise_error(Empeira::ConfigurationError) do |error|
        expect(error.message).to match(/permissions.*chmod 600/)
        expect(error.message).not_to include('synthetic private key contents')
      end
    end
  end

  it 'rejects a key that is not readable' do
    allow(identity).to receive(:path_for).with(key.to_s).and_return(key)
    allow(key).to receive(:readable?).and_return(false)
    expect { identity.resolve(key.to_s) }.to raise_error(Empeira::ConfigurationError, /readable regular/)
  end

  [nil, '', "/key\n", "/key\0"].each do |value|
    it "rejects malformed key paths #{value.inspect}" do
      expect { identity.resolve(value) }.to raise_error(Empeira::ConfigurationError, /SSH identity/)
    end
  end
end
