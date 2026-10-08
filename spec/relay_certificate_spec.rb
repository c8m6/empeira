# frozen_string_literal: true

RSpec.describe Empeira::Server::RelayCertificate do
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:relay) { described_class.new(context: context) }
  let(:directory) { Pathname(relay.path('cert.pem')).dirname }

  it 'removes its exact current identity while preserving unrelated files and directories' do
    directory.mkpath
    %w[cert.pem key.pem cert.pem.pending key.pem.pending].each { |name| directory.join(name).write('synthetic') }
    directory.join('foreign.txt').write('preserve')
    sibling = directory.parent.join('puppetdb-relay-foreign')
    sibling.mkpath
    sibling.join('key.pem').write('preserve')
    relay.cleanup
    expect(directory.children.map { |path| path.basename.to_s }).to eq(['foreign.txt'])
    expect(sibling.join('key.pem').read).to eq('preserve')
  end

  it 'removes a certificate symlink without following it' do
    directory.mkpath
    foreign = Pathname(@directory).join('foreign.pem')
    foreign.write('preserve')
    File.symlink(foreign, directory.join('key.pem'))
    relay.cleanup
    expect(foreign.read).to eq('preserve')
    expect(directory).not_to exist
  end

  it 'reports a removal failure and retains evidence instead of claiming successful cleanup' do
    directory.mkpath
    directory.join('cert.pem').write('synthetic-certificate')
    directory.join('key.pem').write('synthetic-key')
    allow(File).to receive(:unlink).and_call_original
    allow(File).to receive(:unlink).with(relay.path('cert.pem')).and_raise(Errno::EACCES)
    expect { relay.cleanup }.to raise_error(Empeira::Error, /cleanup is incomplete/)
    expect(directory.join('cert.pem')).to exist
    expect(directory.join('key.pem')).to exist
  end

  it 'rejects a linked directory during preparation and cleanup without changing its target' do
    foreign = Pathname(@directory).join('foreign-certificates')
    foreign.mkpath
    foreign.join('key.pem.pending').write('preserve')
    directory.parent.mkpath
    File.symlink(foreign, directory)
    expect { relay.prepare(runtime: nil, server: nil) }.to raise_error(Empeira::Error, /unsafe symlink/)
    expect { relay.cleanup }.to raise_error(Empeira::Error, /unsafe symlink/)
    expect(foreign.join('key.pem.pending').read).to eq('preserve')
  end
end
