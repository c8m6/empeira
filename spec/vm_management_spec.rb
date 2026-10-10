# frozen_string_literal: true

RSpec.describe Empeira::VM::Management do
  let(:record) { { 'management_layout' => described_class::VERSION, 'peer' => { 'token' => 'a' * 32 } } }

  it 'seeds numeric-root VirtIO execution before project bootstrap without login or network authentication' do
    files = described_class.files(record, system_key: 'ssh-ed25519 synthetic-system').to_h do |entry|
      [entry.fetch('path'), entry]
    end
    unit = files.fetch(described_class::UNIT).fetch('content')
    expect(unit).to include('User=0', 'Group=0', described_class::DEVICE, 'RuntimeDirectoryMode=0700')
    expect(unit).not_to match(/^(?:PAMName|ExecStart.*sudo|Requires=.*ssh)/)
    setup = files.fetch(described_class::SETUP).fetch('content')
    expect(setup).to include('systemctl enable --now empeira-management.service', 'verify_account creating')
    expect(setup).not_to include('usermod', 'shadow root', 'ssh-keygen', 'nsenter', '22222')
    agent = files.fetch(described_class::AGENT).fetch('content')
    expect(agent).to include('os.geteuid() != 0', 'start_new_session=True', 'os.killpg', 'os.replace')
    expect(agent).not_to include('getpwnam', '/etc/shadow', 'sudo', 'sshd')
    expect(files.keys).not_to include('/root/.ssh/authorized_keys')
  end

  it 'rejects missing, old and unknown layouts without mutating their records' do
    expect(Empeira::Node::Inventory.valid_vm_management_layout?(record)).to be(true)
    [nil, 0, 2, 3, '1', true].each do |version|
      invalid = record.merge('management_layout' => version)
      original = Marshal.dump(invalid)
      expect { described_class.validate!(invalid) }.to raise_error(Empeira::Error, /preserve the VM.*recreate/)
      expect(Empeira::Node::Inventory.valid_vm_management_layout?(invalid)).to be(false)
      expect(Marshal.dump(invalid)).to eq(original)
    end
    expect { described_class.validate!('ssh_layout' => 3) }.to raise_error(Empeira::Error, /recreate/)
  end

  it 'rejects injectable instance identities before writing the service' do
    expect { described_class.files(record.merge('peer' => { 'token' => "bad\nExecStart=foreign" }), system_key: 'key') }
      .to raise_error(Empeira::Error, /instance identity/)
  end

  it 'validates the persisted management socket identity' do
    valid = record.merge('management_socket' => { 'device' => 1, 'inode' => 2 })
    expect(Empeira::Node::Inventory.valid_vm_management_layout?(valid)).to be(true)
    expect(Empeira::Node::Inventory.valid_vm_management_layout?(valid.merge('management_socket' => { 'inode' => 2 })))
      .to be(false)
  end
end
