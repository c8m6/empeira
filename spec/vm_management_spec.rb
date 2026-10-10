# frozen_string_literal: true

RSpec.describe Empeira::VM::Management do
  let(:record) do
    { 'hostname' => 'node.example.test', 'ssh_layout' => 1, 'ssh_port' => 32_123,
      'mac_address' => '52:54:00:12:34:56', 'peer' => { 'ip' => '10.203.20.32' } }
  end
  let(:app) { Empeira::Application.new(project_path: @directory) }

  it 'seeds an independent key-only daemon restricted to the existing management NIC' do
    files = described_class.files(record, 'ssh-ed25519 synthetic-management-public-key')
    config = files.find { |entry| entry['path'] == described_class::CONFIG }.fetch('content')
    expect(config).to include('Port 22222', 'ListenAddress 10.0.2.15', 'PermitRootLogin no',
                              'PasswordAuthentication no', 'KbdInteractiveAuthentication no',
                              'AuthenticationMethods publickey', 'AllowUsers empeira', 'PermitOpen 10.203.20.32:*')
    expect(config).not_to include('Include ', '/etc/ssh/sshd_config', '/home/empeira/.ssh')
    unit = files.find { |entry| entry['path'] == described_class::UNIT }.fetch('content')
    expect(unit).to include('RuntimeDirectory=empeira-management-ssh',
                            'TemporaryFileSystem=/run /var/empty /run/sshd:ro /var/empty/sshd:ro',
                            'BindPaths=/run/empeira-management-ssh')
    expect(unit).to include('exec restorecon -R /run/empeira-management-ssh')
    expect(unit).not_to match(/^(?:Requires|Wants|PartOf)=.*sshd?\.service/)
    checker = files.find { |entry| entry['path'] == described_class::CHECK }.fetch('content')
    expect(checker).to include(Digest::SHA256.hexdigest(config), Digest::SHA256.hexdigest(unit))
    policy = files.find { |entry| entry['path'].end_with?('/empeira_management.cil') }.fetch('content')
    expect(policy).to include('(portcon tcp 22222', '/run/empeira-management-ssh', '/etc/empeira/management/')
    expect(policy).not_to include('(allow ', '(permissive ', 'unconfined', '(portcon tcp 22 ')
  end

  it 'rejects unsafe system SSH destinations before generating guest configuration' do
    %w[203.0.113.10 ::1].each do |ip|
      expect { described_class.configuration(record.merge('peer' => { 'ip' => ip })) }
        .to raise_error(Empeira::Error, /isolated IPv4/)
    end
  end

  it 'retains the legacy forwarding target and adds no management NIC for the new layout' do
    legacy = Empeira::Network::Peer::Management.new(record.except('ssh_layout')).arguments
    modern = Empeira::Network::Peer::Management.new(record).arguments
    expect(legacy[1]).to end_with('32123-:22')
    expect(modern[1]).to end_with('32123-10.0.2.15:22222')
    expect(modern.count('-device')).to eq(1)
    expect(modern[1]).to include('restrict=on', '127.0.0.1:')
  end

  it 'rejects unknown persisted layout versions without rejecting legacy records' do
    expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record)).to be(true)
    expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record.merge('ssh_layout' => 2))).to be(true)
    expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record.except('ssh_layout'))).to be(true)
    [nil, 0, 3, '1', true].each do |version|
      expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record.merge('ssh_layout' => version))).to be(false)
    end
  end

  it 'keeps independent management and system keys and host-key stores across repeated preparation' do
    credentials = %i[management system].map do |purpose|
      Empeira::Node::SSHCredentials.new(context: app.context, runner: app.runner, provider: 'vm',
                                        hostname: record.fetch('hostname'), purpose: purpose)
    end
    credentials.each(&:prepare)
    management, system = credentials
    expect(management.public_path.read).not_to eq(system.public_path.read)
    expect(management.known_hosts).not_to eq(system.known_hosts)
    previous = management.key_path.read
    management.prepare
    expect(management.key_path.read).to eq(previous)
    expect(system.key_path.basename.to_s).to eq('id_ed25519')
  end

  it 'starts management before project scripts and leaves system authentication independent in cloud-init' do
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    credentials = Empeira::Node::SSHCredentials.new(context: app.context, runner: app.runner, provider: 'vm',
                                                    hostname: record.fetch('hostname'), purpose: :management)
    credentials.prepare
    config = cloud.send(:cloud_config, record, 'ssh-ed25519 synthetic-system-public-key')
    expect(config.fetch('users').first.fetch('ssh_authorized_keys')).to eq(['ssh-ed25519 synthetic-system-public-key'])
    expect(config.fetch('write_files').find { |entry| entry['path'].end_with?('/authorized_keys') }
      .fetch('content')).to eq(credentials.public_path.read)
    expect(config['runcmd']).to include([described_class::SETUP])
    expect(cloud.send(:management_network, record)).to eq('dhcp4' => false, 'addresses' => ['10.0.2.15/24'])
    expect(cloud.send(:management_network, record.except('ssh_layout'))).to include('dhcp4' => true)
  end

  it 'creates a locked system account and explicitly prepares its private home before management starts' do
    modern = record.merge('ssh_layout' => 2)
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    credentials = Empeira::Node::SSHCredentials.new(context: app.context, runner: app.runner, provider: 'vm',
                                                    hostname: record.fetch('hostname'), purpose: :management)
    credentials.prepare
    config = cloud.send(:cloud_config, modern, 'ssh-ed25519 synthetic-system-public-key')
    user = config.fetch('users').first
    expect(user).to include('system' => true, 'homedir' => '/var/lib/empeira', 'lock_passwd' => true,
                            'shell' => '/bin/bash', 'sudo' => 'ALL=(ALL) NOPASSWD:ALL')
    expect(user).not_to have_key('ssh_authorized_keys')
    expect(user).not_to have_key('uid')
    files = config.fetch('write_files').to_h { |entry| [entry.fetch('path'), entry] }
    expect(files.fetch("#{described_class::DIRECTORY}/system_authorized_keys").fetch('content'))
      .to eq("ssh-ed25519 synthetic-system-public-key\n")
    setup = files.fetch(described_class::SETUP).fetch('content')
    expect(setup).to include('verify_account creating', 'install -d -m 0700',
                             '/var/lib/empeira/.ssh/authorized_keys', 'verify_account verified')
    expect(setup.index('verify_account creating')).to be < setup.index('systemctl enable --now')
    expect(files.fetch(described_class::CHECK).fetch('content')).to include('verify_account verified')
  end

  it 'retains the original regular account home for legacy and first separated layouts' do
    expect(described_class.home(record.except('ssh_layout'))).to eq('/home/empeira')
    expect(described_class.home(record)).to eq('/home/empeira')
    expect(described_class.home(record.merge('ssh_layout' => 2))).to eq('/var/lib/empeira')
    expect(described_class.files(record, 'synthetic-key').map { |entry| entry['content'] }.join)
      .not_to include('verify_account creating', 'verify_account verified')
  end
end

RSpec.describe Empeira::VM::SystemSSH do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:management) { instance_double(Empeira::VM::SSH) }
  let(:peer) { instance_double(Empeira::Network::Peer::LinuxPodman) }
  let(:system) { described_class.new(context: app.context, runner: app.runner, management: management, peer: peer) }
  let(:record) { { 'hostname' => 'node.example.test', 'ssh_port' => 32_123 } }

  it 'preserves legacy endpoints without invoking separate management or migrating state' do
    expect(management).not_to receive(:system_proxy_command)
    expect(peer).to receive(:ssh_command).with(record).and_return(nil)
    client = instance_double(Empeira::Node::UserSSH)
    allow(Empeira::Node::UserSSH).to receive(:new).and_return(client)
    expect(client).to receive(:session).with(record, user: nil, identity: nil)
    system.session(record)
    expect { system.session(record, port: 2222) }.to raise_error(Empeira::Error, /Legacy VM SSH layout/)
    expect(record).not_to have_key('ssh_layout')
  end

  it 'uses the selected guest port for system SSH and keeps the stored management endpoint' do
    record['ssh_layout'] = 1
    expect(management).to receive(:system_proxy_command).with(record, port: 2222).and_return(['private-tunnel'])
    expect(peer).not_to receive(:ssh_command)
    client = instance_double(Empeira::Node::UserSSH)
    allow(Empeira::Node::UserSSH).to receive(:new).with(hash_including(proxy_command: ['private-tunnel']))
                                                  .and_return(client)
    expect(client).to receive(:session).with(record.merge('ssh_port' => 2222), user: 'admin', identity: '/personal/key')
    system.session(record, user: 'admin', identity: '/personal/key', port: 2222)
    expect(record['ssh_port']).to eq(32_123)
  end
end
