# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'
require_relative '../support/node_access'
require_relative '../support/login_fixture'
require_relative '../support/console_login'

RSpec.describe 'Real node runtime management', :integration do
  include LiveNodeAccess
  include LiveConsoleLogin

  let(:engine_name) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:hostname) { 'runtime-node.example.test' }
  let(:devices) do
    { 'dummy0' => { 'network' => '192.0.2.10/32' },
      'ens192' => { 'network' => '198.51.100.10/24', 'vlan_id' => 123 } }
  end
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end

  def app
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine_name } })
  end

  before do
    skip 'Set EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION=1 for real package and runtime management checks' unless
      ENV['EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    destinations = app.context.configuration.dig('bootstrap', 'guests', 'ubuntu', '24.04', 'destinations')
    @config = { 'puppetdb' => { 'enabled' => false },
                'vm' => { 'disk' => 30,
                          'interfaces' => [{ 'hosts' => ['RUNTIME-*.EXAMPLE.TEST'], 'devices' => devices }] },
                'proxy' => { 'enabled' => true, 'global' => destinations } }
    write_configuration
    @runtime = Empeira::Runtime.registry.build(engine_name, context: app.context, runner: app.runner)
    @runtime.check_available!
    @login = LoginFixture.new(directory: @directory)
  end

  after do
    next unless ENV['EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION'] == '1' && File.directory?(project)

    app.infrastructure.destroy if Empeira::Infrastructure::Store.new(context: app.context).load
  end

  %w[container vm].each do |provider|
    it "installs a package through Puppet's normal proxy and reconciles retained #{provider} nodes" do
      selected = ENV.fetch('EMPEIRA_RUNTIME_MANAGEMENT_PROVIDERS', 'container,vm').split(',')
      skip "Provider #{provider} not selected" unless selected.include?(provider)

      @provider = provider
      Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight! if provider == 'vm'
      File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
        #{@login.manifest}
        #{interface_manifest if provider == 'vm'}
        exec { 'runtime-package-index':
          command => '/usr/bin/apt-get update',
          unless => '/usr/bin/test -e /tmp/empeira-package-index',
          before => Package['tree'],
        }
        package { 'tree': ensure => installed }
        file { '/tmp/empeira-package-index': ensure => file, require => Package['tree'] }
      PUPPET
      app.infrastructure.up
      app.run_node(hostname: hostname, provider: provider)
      verify_combined_vm if provider == 'vm'
      expect(guest(%w[tree --version]).stdout).to include('tree')
      verify_interactive_tools
      expect(guest(['test', '!', '-e', Empeira::Node::PackageProxy::APT_PATH])).to be_success
      Empeira::Node::PackageSources.verify!(execute: ->(arguments) { guest(arguments) })
      identity = record.slice('id', 'pid', 'peer', 'overlay')
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
      app.nodes.stop(name: hostname)
      app.nodes.start(name: hostname)
      verify_combined_vm if provider == 'vm'
      expect(guest(%w[tree --version])).to be_success
      verify_interactive_tools
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
      @config['proxy']['enabled'] = false
      write_configuration
      app.infrastructure.up
      expect(guest(['test', '!', '-e', Empeira::RuntimeProxyGuest::APT_PATH])).to be_success
      @config['proxy']['enabled'] = true
      write_configuration
      app.infrastructure.up
      expect(guest(%w[apt-get update])).to be_success
      expect(record.slice('id', 'peer', 'overlay')).to eq(identity.slice('id', 'peer', 'overlay'))
      verify_separate_vm_ssh if provider == 'vm'
    end
  end

  def interface_manifest
    <<~PUPPET
      $dummy = $facts['networking']['interfaces']['dummy0']['bindings'][0]['address']
      $vlan = $facts['networking']['interfaces']['ens192']['bindings'][0]['address']
      file { '/tmp/empeira-first-interface-facts': content => "${dummy}|${vlan}" }
    PUPPET
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Observe the real combined guest and immutable thin disk.
  def verify_combined_vm
    overlay = app.context.locations.workspace(app.context.workspace).join(record.fetch('overlay'))
    engine = Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner)
    metadata = app.runner.run(engine.image_tool, arguments: ['info', '--force-share', '--output=json', overlay.to_s])
    expect(metadata).to be_success
    disk = JSON.parse(metadata.stdout)
    expect(disk.fetch('virtual-size')).to eq(30 * Empeira::VM::Disk::GIB)
    expect(Digest::SHA256.file(disk.fetch('backing-filename')).hexdigest).to eq(record.dig('base_image', 'checksum'))
    expect(File.stat(overlay).blocks * 512).to be < 8 * Empeira::VM::Disk::GIB
    Empeira::VM::RootDisk.new(ssh: management_ssh).verify!(record, size_gib: 30)
    expect(guest(%w[cat /tmp/empeira-first-interface-facts]).stdout).to eq('192.0.2.10|198.51.100.10')
    links = JSON.parse(guest(%w[ip -j -d link show]).stdout).to_h { |entry| [entry.fetch('ifname'), entry] }
    expect(links.dig('dummy0', 'linkinfo', 'info_kind')).to eq('dummy')
    expect(links.dig('ens192', 'linkinfo', 'info_kind')).to eq('vlan')
    expect(links.dig('ens192', 'linkinfo', 'info_data', 'id')).to eq(123)
    account = guest(%w[getent passwd empeira]).stdout.split(':')
    expect(account[5..6].map(&:strip)).to eq(['/var/lib/empeira', '/bin/bash'])
    uid_min = guest(['awk', '$1 == "UID_MIN" { print $2 }', '/etc/login.defs']).stdout.to_i
    expect(account[2].to_i).to be_between(1, uid_min - 1)
    expect(guest(['stat', '-c', '%u:%g:%a', '/var/lib/empeira']).stdout.strip).to eq("#{account[2]}:#{account[3]}:700")
    expect(guest(['sh', '-c',
                  'case "$(getent shadow empeira | cut -d : -f 2)" in \\!*|\\**) exit 0;; *) exit 1;; esac']))
      .to be_success
    result, output, error = access_session(app, name: hostname, operation: :ssh)
    expect(result.exit_status).to eq(7), error
    expect(output).to include('empeira')
  end

  def write_configuration
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
  end

  def record
    Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch(hostname)
  end

  def guest(arguments)
    if @provider == 'vm'
      management_ssh.run(record, arguments, timeout: 300)
    else
      definition = Empeira::Node::Definition.new(hostname: hostname, workspace: app.context.workspace)
      @runtime.service_exec(@runtime.inspect_service(definition), arguments, timeout: 300)
    end
  end

  def management_ssh
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Follow both real SSH daemons across Puppet and reboot.
  def verify_separate_vm_ssh
    expect(record.fetch('ssh_layout')).to eq(Empeira::VM::Management::VERSION)
    expect(guest(%w[systemctl is-active empeira-management-ssh.service])).to be_success
    expect(guest(%w[systemctl is-active ssh.service])).to be_success
    original = File.read(File.join(project, 'manifests/site.pp'))
    system_config = "Port 2222\nListenAddress #{record.fetch('peer').fetch('ip')}\n" \
                    "HostKey /etc/ssh/ssh_host_ed25519_key\nUsePAM yes\nPasswordAuthentication no\n" \
                    "KbdInteractiveAuthentication no\nPermitRootLogin no\nSubsystem sftp internal-sftp\n"
    manifest = <<~PUPPET
      #{original}
      service { 'ssh.socket': ensure => stopped, enable => false,
        before => File['/etc/systemd/system/ssh.service'] }
      file { '/etc/systemd/system/ssh.service':
        ensure => file, owner => 'root', group => 'root', mode => '0644',
        content => '[Unit]
      Description=Puppet-managed system SSH
      After=network.target
      [Service]
      Type=simple
      RuntimeDirectory=sshd
      RuntimeDirectoryMode=0755
      ExecStartPre=/usr/sbin/sshd -t -f /etc/ssh/sshd_config
      ExecStart=/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
      KillMode=control-group
      [Install]
      WantedBy=multi-user.target
      ', notify => Exec['reload-system-sshd-unit'],
      }
      exec { 'reload-system-sshd-unit': command => '/bin/systemctl daemon-reload',
        refreshonly => true, before => File['/etc/ssh/sshd_config'] }
      file { '/etc/ssh/sshd_config':
        ensure => file, owner => 'root', group => 'root', mode => '0644',
        content => '#{system_config}', notify => Service['ssh'],
      }
      service { 'ssh': ensure => running, enable => true }
    PUPPET
    File.write(File.join(project, 'manifests/site.pp'), manifest)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    result, output, error = access_session(app, name: hostname, operation: :ssh, port: 2222,
                                                user: @login.username, identity: @login.identity.to_s)
    expect(result.exit_status).to eq(7), error
    expect(output).to include(@login.username)
    expect(guest(%w[systemctl is-active empeira-management-ssh.service])).to be_success
    restarted = manifest.sub('Subsystem sftp internal-sftp', "Subsystem sftp internal-sftp\n# Puppet restart probe")
    File.write(File.join(project, 'manifests/site.pp'), restarted)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    expect(guest(%w[systemctl is-active empeira-management-ssh.service])).to be_success
    manifest = restarted
    manifest = manifest.sub("service { 'ssh': ensure => running, enable => true }",
                            "service { 'ssh': ensure => stopped, enable => false }")
    File.write(File.join(project, 'manifests/site.pp'), manifest)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    result, = access_session(app, name: hostname, operation: :ssh, port: 2222,
                                  user: @login.username, identity: @login.identity.to_s)
    expect(result.exit_status).not_to eq(0)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
    app.nodes.stop(name: hostname)
    app.nodes.start(name: hostname)
    expect(guest(%w[systemctl is-active empeira-management-ssh.service])).to be_success
    expect(guest(%w[systemctl is-enabled empeira-management-ssh.service])).to be_success
    expect(guest(%w[systemctl is-active ssh.service])).not_to be_success
    expect(guest(%w[systemctl is-enabled ssh.service])).not_to be_success
    wait_for_puppet_idle
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
  end

  def wait_for_puppet_idle
    lock = guest([Empeira::Node::Certificates::PUPPET, 'config', 'print', 'agent_catalog_run_lock']).stdout.strip
    Timeout.timeout(180) do
      loop do
        return if guest(['test', '!', '-e', lock]).success?

        sleep 1
      end
    end
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Check root/user and provider interactive transports together.
  def verify_interactive_tools
    command = 'command -v puppet; command -v facter; puppet --version; facter --version'
    expect(guest(['bash', '--login', '-ic', command])).to be_success
    expect(guest(['bash', '-ic', command])).to be_success
    result = guest(['su', '--login', '--shell', '/bin/bash', '--command', "bash -ic '#{command}'", @login.username])
    expect(result).to be_success, result.stderr
    current = app
    options = { user: @login.username, identity: @login.identity.to_s }
    commands = "#{command}\nprintf 'tools-exit=%s\\n' \"$?\"\nexit 7\n"
    status, output, error = access_session(current, name: hostname, operation: :ssh, commands: commands, **options)
    expect(status.exit_status).to eq(7), error
    expect(output).to include('/opt/puppetlabs/bin/puppet', '/opt/puppetlabs/bin/facter', 'tools-exit=0')
    if @provider == 'vm'
      output = verify_console_login(current, name: hostname,
                                             commands: "id\n#{command}\nprintf 'tools-exit=%s\\n' \"$?\"\nexit\n")
      expect(output).to include('/opt/puppetlabs/bin/puppet', '/opt/puppetlabs/bin/facter', 'tools-exit=0')
      return
    end

    status, output, error = access_session(current, name: hostname, operation: :shell, commands: commands)
    expect(status.exit_status).to eq(7), error
    expect(output).to include('/opt/puppetlabs/bin/puppet', '/opt/puppetlabs/bin/facter', 'tools-exit=0')
  end
end
