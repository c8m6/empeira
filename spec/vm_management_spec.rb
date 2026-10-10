# frozen_string_literal: true

RSpec.describe Empeira::VM::Management do
  let(:record) do
    { 'hostname' => 'node.example.test', 'ssh_layout' => described_class::VERSION, 'ssh_port' => 32_123,
      'mac_address' => '52:54:00:12:34:56', 'peer' => { 'ip' => '10.203.20.32' } }
  end
  let(:app) { Empeira::Application.new(project_path: @directory) }

  it 'seeds an independent key-only daemon restricted to the existing management NIC' do
    files = described_class.files(record, 'ssh-ed25519 synthetic-management-public-key', system_key: 'synthetic-system')
    config = files.find { |entry| entry['path'] == described_class::CONFIG }.fetch('content')
    expect(config).to include('Port 22222', 'ListenAddress 10.0.2.15', 'PermitRootLogin prohibit-password', 'UsePAM no',
                              'PasswordAuthentication no', 'KbdInteractiveAuthentication no',
                              'AuthenticationMethods publickey', 'AllowUsers root', 'PermitOpen 10.203.20.32:*')
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

  it 'uses only the restricted management NIC and rejects old forwarding layouts' do
    modern = Empeira::Network::Peer::Management.new(record).arguments
    expect(modern[1]).to end_with('32123-10.0.2.15:22222')
    expect(modern.count('-device')).to eq(1)
    expect(modern[1]).to include('restrict=on', '127.0.0.1:')
    expect { Empeira::Network::Peer::Management.new(record.except('ssh_layout')).arguments }
      .to raise_error(Empeira::Error, /Incompatible VM management SSH layout/)
  end

  it 'rejects missing, old and unknown persisted layouts without migration' do
    expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record)).to be(true)
    [nil, 0, 1, 2, 4, '3', true].each do |version|
      old = record.merge('ssh_layout' => version)
      expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(old)).to be(false)
      expect { described_class.validate!(old) }.to raise_error(Empeira::Error, /preserve the VM.*destroy it explicitly/)
      expect(old['ssh_layout']).to eq(version)
    end
    expect(Empeira::Node::Inventory.valid_vm_ssh_layout?(record.except('ssh_layout'))).to be(false)
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
    expect(config.fetch('users').first).not_to have_key('ssh_authorized_keys')
    expect(config.fetch('write_files').find { |entry| entry['path'].end_with?('/authorized_keys') }
      .fetch('content')).to eq(credentials.public_path.read)
    expect(config['runcmd']).to include([described_class::SETUP])
    expect(cloud.send(:management_network, record)).to eq('dhcp4' => false, 'addresses' => ['10.0.2.15/24'])
    expect { cloud.send(:management_network, record.except('ssh_layout')) }
      .to raise_error(Empeira::Error, /Incompatible VM management SSH layout/)
  end

  it 'keeps the regular system SSH login without sudo or management health dependencies' do
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    credentials = Empeira::Node::SSHCredentials.new(context: app.context, runner: app.runner, provider: 'vm',
                                                    hostname: record.fetch('hostname'), purpose: :management)
    credentials.prepare
    config = cloud.send(:cloud_config, record, 'ssh-ed25519 synthetic-system-public-key')
    user = config.fetch('users').first
    expect(user).to include('name' => 'empeira', 'system' => true, 'homedir' => '/var/lib/empeira',
                            'lock_passwd' => true, 'shell' => '/bin/bash')
    expect(user).not_to have_key('sudo')
    expect(user).not_to have_key('ssh_authorized_keys')
    files = config.fetch('write_files').to_h { |entry| [entry.fetch('path'), entry] }
    expect(files.fetch("#{described_class::DIRECTORY}/system_authorized_keys").fetch('content'))
      .to eq("ssh-ed25519 synthetic-system-public-key\n")
    expect(files.fetch("#{described_class::DIRECTORY}/authorized_keys")).to include('permissions' => '0600')
    setup = files.fetch(described_class::SETUP).fetch('content')
    expect(setup).to include('verify_account creating', '/var/lib/empeira/.ssh/authorized_keys',
                             'usermod --password', 'install -d -m 0700 -o root -g root')
    checker = files.fetch(described_class::CHECK).fetch('content')
    expect(checker).to include('verify_root', 'management session is not root')
    expect(checker).not_to include('getent passwd empeira', '/var/lib/empeira', 'sudo', 'verify_account')
    expect(files.fetch(described_class::POLICY).fetch('content')).to include('sshd -T', "require 'allowusers root'")
  end
end
