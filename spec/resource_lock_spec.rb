# frozen_string_literal: true

RSpec.describe Empeira::Infrastructure::ResourceLock do
  let(:context) { Empeira::Application.new(project_path: @directory).context }
  let(:store) { Empeira::Infrastructure::Store.new(context: context) }

  it 'serializes only the same technical resource and permits nested acquisition' do
    ready = Queue.new
    entered = Queue.new
    worker = nil
    store.resource_lock('discovery').synchronize do
      store.resource_lock('discovery').synchronize { expect(true).to be(true) }
      store.resource_lock('gateway-policy').synchronize { expect(true).to be(true) }
      worker = Thread.new do
        ready << true
        store.resource_lock('discovery').synchronize { entered << true }
      end
      ready.pop
      expect(entered).to be_empty
      expect { store.with_lock { nil } }.not_to raise_error
    end
    expect(Timeout.timeout(5) { entered.pop }).to be(true)
    worker.join
  ensure
    worker&.kill
  end

  it 'releases its lock after interruption and retains the same inode' do
    lock = store.resource_lock('discovery')
    expect { lock.synchronize { raise Interrupt } }.to raise_error(Interrupt)
    path = store.directory.join('locks').children.fetch(0)
    inode = path.stat.ino
    expect { lock.synchronize { expect(path.stat.ino).to eq(inode) } }.not_to raise_error
  end

  it 'refuses symlinks and foreign-readable lock files' do
    lock = store.resource_lock('discovery')
    lock.synchronize { nil }
    path = store.directory.join('locks').children.fetch(0)
    other = Pathname(@directory).join('foreign')
    other.write('preserve')
    path.unlink
    File.symlink(other, path)
    expect { lock.synchronize { nil } }.to raise_error(Errno::ELOOP)
    expect(other.read).to eq('preserve')
    path.unlink
    path.write('')
    path.chmod(0o644)
    expect { lock.synchronize { nil } }.to raise_error(Empeira::Infrastructure::StateError)
  end
end
