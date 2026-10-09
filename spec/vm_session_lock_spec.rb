# frozen_string_literal: true

RSpec.describe Empeira::VM::SessionLock do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
  let(:record) { { 'hostname' => 'vm-node', 'peer' => { 'token' => 'a' * 32 } } }
  let(:guard) { described_class.new(context: app.context, record: record) }

  before { store.with_lock { nil } }

  it 'allows parallel access and independent workspace commands while excluding conflicting lifecycle operations' do
    first = guard.acquire(shared: true)
    second = guard.acquire(shared: true)
    expect { store.with_lock { nil } }.not_to raise_error
    expect { guard.exclusive { raise 'must not enter' } }.to raise_error(Empeira::Infrastructure::Locked)
    expect(first.close_on_exec?).to be(true)
    second.close
    expect { guard.exclusive { nil } }.to raise_error(Empeira::Infrastructure::Locked)
    first.close
    expect { guard.exclusive { nil } }.not_to raise_error
  ensure
    [first, second].compact.each { |lock| lock.close unless lock.closed? }
  end

  it 'keeps locks specific to the recorded node instance' do
    lock = guard.acquire(shared: true)
    replacement = record.merge('peer' => { 'token' => 'b' * 32 })
    other = described_class.new(context: app.context, record: replacement)
    expect { other.exclusive { nil } }.not_to raise_error
  ensure
    lock&.close
  end

  [RuntimeError, Interrupt, SignalException].each do |error|
    it "releases its exclusive guard after #{error}" do
      failure = error == SignalException ? SignalException.new('TERM') : error.new
      expect { guard.exclusive { raise failure } }.to raise_error(error)
      expect { guard.exclusive { nil } }.not_to raise_error
    end
  end

  it 'refuses unsafe lock files without affecting another resource' do
    path = store.directory.join("vm-session-#{'a' * 32}.lock")
    other = Pathname(@directory).join('foreign-file')
    other.write('preserve')
    File.symlink(other, path)
    expect { guard.acquire(shared: true) }.to raise_error(Empeira::Providers::OwnershipError)
    expect(other.read).to eq('preserve')
    path.unlink
    path.write('')
    path.chmod(0o644)
    expect { guard.acquire(shared: true) }.to raise_error(Empeira::Providers::OwnershipError)
  end
end
