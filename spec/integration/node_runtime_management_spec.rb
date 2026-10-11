# frozen_string_literal: true

require_relative '../../resources/nodes/runtime_proxy'
require_relative '../support/node_access'
require_relative '../support/login_fixture'
require_relative '../support/console_login'
require_relative '../support/agent_entry_probe'

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
        file { '/var/lib/empeira-runtime-fixture': ensure => directory, mode => '0700' }
        #{interface_manifest if provider == 'vm'}
        service { 'puppet': ensure => stopped, enable => false }
        exec { 'runtime-package-index':
          command => '/usr/bin/apt-get update',
          unless => '/usr/bin/test -e /var/lib/empeira-runtime-fixture/package-index',
          before => Package['tree'],
        }
        package { 'tree': ensure => installed }
        file { '/var/lib/empeira-runtime-fixture/package-index': ensure => file, require => Package['tree'] }
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
      if provider == 'vm'
        wait_for_puppet_idle
        expect([0, 2]).to include(app.nodes.puppet(name: hostname).exit_status)
      end
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

  it 'preserves VirtIO management and independent user SSH after Puppet locks root' do
    selected = ENV.fetch('EMPEIRA_RUNTIME_MANAGEMENT_PROVIDERS', 'container,vm').split(',')
    skip 'Provider vm not selected' unless selected.include?('vm')

    @provider = 'vm'
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      #{@login.manifest}
      file { '/var/lib/empeira-runtime-fixture': ensure => directory, mode => '0700' }
      #{interface_manifest}
      service { 'puppet': ensure => stopped, enable => false }
    PUPPET
    app.infrastructure.up
    app.run_node(hostname: hostname, provider: 'vm')
    result, output, error = access_session(app, name: hostname, operation: :ssh)
    expect(result.exit_status).to eq(7), error
    expect(output).to include('empeira')
    verify_separate_vm_ssh
  end

  def interface_manifest
    <<~PUPPET
      $dummy = $facts['networking']['interfaces']['dummy0']['bindings'][0]['address']
      $vlan = $facts['networking']['interfaces']['ens192']['bindings'][0]['address']
      file { '/var/lib/empeira-runtime-fixture/first-interface-facts': content => "${dummy}|${vlan}" }
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
    Empeira::VM::RootDisk.new(guest: management_guest).verify!(record, size_gib: 30)
    facts = guest(%w[cat /var/lib/empeira-runtime-fixture/first-interface-facts]).stdout
    expect(facts).to eq('192.0.2.10|198.51.100.10')
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
      management_guest.run(record, arguments, timeout: 300)
    else
      definition = Empeira::Node::Definition.new(hostname: hostname, workspace: app.context.workspace)
      @runtime.service_exec(@runtime.inspect_service(definition), arguments, timeout: 300)
    end
  end

  def management_guest
    vm_guest(app)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Follow real management and system SSH across Puppet and reboot.
  def verify_separate_vm_ssh
    expect(record.fetch('management_layout')).to eq(Empeira::VM::Management::VERSION)
    expect(guest(%w[id -u]).stdout.strip).to eq('0')
    verify_management_channel
    expect(guest(%w[systemctl is-active empeira-management.service])).to be_success
    expect(guest(%w[systemctl is-active ssh.service])).to be_success
    wait_for_system_login_exit
    original = File.read(File.join(project, 'manifests/site.pp'))
    system_config = "Port 2222\nListenAddress #{record.fetch('peer').fetch('ip')}\n" \
                    "HostKey /etc/ssh/ssh_host_ed25519_key\nUsePAM yes\nPasswordAuthentication no\n" \
                    "KbdInteractiveAuthentication no\nPermitRootLogin no\nSubsystem sftp internal-sftp\n"
    manifest = <<~PUPPET
      #{original}
      user { 'root': ensure => present, password => '!' }
      file { '/etc/sudoers': ensure => file, owner => 'root', group => 'root', mode => '0440',
        content => "root ALL=(ALL:ALL) ALL\n" }
      file { '/etc/sudoers.d': ensure => directory, recurse => true, purge => true, force => true }
      user { 'empeira': ensure => absent }
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
    expect(guest(['sh', '-c', 'test "$(getent shadow root | cut -d : -f 2)" = "!"'])).to be_success
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
    verify_failed_catalog_retry(manifest)
    measure_agent_entry
    result, output, error = access_session(app, name: hostname, operation: :ssh, port: 2222,
                                                user: @login.username, identity: @login.identity.to_s)
    expect(result.exit_status).to eq(7), error
    expect(output).to include(@login.username)
    verify_system_ssh_without_management
    expect(guest(%w[systemctl is-active empeira-management.service])).to be_success
    expect(guest(%w[getent passwd empeira])).not_to be_success
    verify_management_upload
    restarted = manifest.sub('Subsystem sftp internal-sftp', "Subsystem sftp internal-sftp\n# Puppet restart probe")
    File.write(File.join(project, 'manifests/site.pp'), restarted)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    expect(guest(%w[systemctl is-active empeira-management.service])).to be_success
    manifest = restarted
    manifest = manifest.sub("service { 'ssh': ensure => running, enable => true }",
                            "service { 'ssh': ensure => stopped, enable => false }")
    File.write(File.join(project, 'manifests/site.pp'), manifest)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    result, = access_session(app, name: hostname, operation: :ssh, port: 2222,
                                  user: @login.username, identity: @login.identity.to_s)
    expect(result.exit_status).not_to eq(0)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
    manifest = manifest.sub("service { 'ssh': ensure => stopped, enable => false }",
                            "service { 'ssh': ensure => running, enable => true }")
    File.write(File.join(project, 'manifests/site.pp'), manifest)
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(2)
    verify_selected_system_ssh
    app.nodes.stop(name: hostname)
    app.nodes.start(name: hostname)
    expect(guest(%w[systemctl is-active empeira-management.service])).to be_success
    expect(guest(%w[systemctl is-enabled empeira-management.service])).to be_success
    expect(guest(%w[systemctl is-active ssh.service])).to be_success
    expect(guest(%w[systemctl is-enabled ssh.service])).to be_success
    expect(guest(['sh', '-c', 'test "$(getent shadow root | cut -d : -f 2)" = "!"'])).to be_success
    verify_selected_system_ssh
    app.infrastructure.up
    facts = guest(%w[cat /var/lib/empeira-runtime-fixture/first-interface-facts]).stdout
    expect(facts).to eq('192.0.2.10|198.51.100.10')
    expect(guest(%w[apt-get update])).to be_success
    wait_for_puppet_idle
    expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Five real agent-entry samples share one restored disposable instrumentation boundary.
  def measure_agent_entry
    script = <<~'SH'
      set -eu
      agent=/opt/puppetlabs/bin/puppet
      backup=/opt/puppetlabs/bin/puppet.empeira-management-original
      test ! -e "$backup"
      test -x /opt/puppetlabs/puppet/bin/puppet
      mv "$agent" "$backup"
      cat > "$agent" <<'WRAPPER'
      #!/bin/sh
      printf 'EMPEIRA_BENCHMARK_AGENT_ENTRY\n'
      exec /opt/puppetlabs/puppet/bin/puppet "$@"
      WRAPPER
      chmod 755 "$agent"
    SH
    expect(guest(['sh', '-eu', '-c', script])).to be_success
    samples = []
    probe_script = File.expand_path('../support/agent_entry_cli.rb', __dir__)
    repository = File.expand_path('../..', __dir__)
    5.times do
      probe = AgentEntryProbe.new
      result = app.runner.run(RbConfig.ruby,
                              arguments: [probe_script, repository, locations.home.to_s, engine_name, hostname],
                              directory: project, on_stdout: probe.method(:<<), timeout: 300)
      expect(result).to be_success, result.stderr
      expect(probe.seconds).not_to be_nil
      samples << probe.seconds
    end
    RSpec.configuration.reporter.message("VirtIO agent entry #{engine_name}: #{JSON.generate(samples)} seconds")
  ensure
    restore = 'test ! -e /opt/puppetlabs/bin/puppet.empeira-management-original || ' \
              'mv -f /opt/puppetlabs/bin/puppet.empeira-management-original /opt/puppetlabs/bin/puppet'
    expect(guest(['sh', '-eu', '-c', restore])).to be_success
  end

  # rubocop:disable-next Metrics/AbcSize -- Inspect the actual private service and persisted ownership.
  def verify_management_channel
    expect(record).not_to have_key('ssh_port')
    expect(record.fetch('management_socket').keys.sort).to eq(%w[device inode])
    expect(guest(%w[id -u]).stdout.strip).to eq('0')
    expect(guest(['stat', '-c', '%u:%g:%a', Empeira::VM::Management::UPLOADS]).stdout.strip).to eq('0:0:700')
    expect(guest(%w[systemctl show -p User -p Group empeira-management.service]).stdout).to include('User=0', 'Group=0')
    expect(guest(%w[test ! -e /usr/local/libexec/empeira-management-check])).to be_success
  end

  def verify_selected_system_ssh
    result, output, error = access_session(app, name: hostname, operation: :ssh, port: 2222,
                                                user: @login.username, identity: @login.identity.to_s)
    expect(result.exit_status).to eq(7), error
    expect(output).to include(@login.username)
  end

  # rubocop:disable-next Metrics/AbcSize -- Remove only the owned socket path while proving independent native user SSH.
  def verify_system_ssh_without_management
    runtime = Empeira::VM::QemuRuntime.new(engine: nil, runner: app.runner, context: app.context)
    socket = runtime.management_socket(record)
    hidden = Pathname("#{socket}.detached")
    File.rename(socket, hidden)
    expect { management_guest.run(record, ['true']) }.to raise_error(Empeira::VM::Guest::TransportError)
    verify_selected_system_ssh
  ensure
    File.rename(hidden, socket) if hidden&.socket?
  end

  # rubocop:disable-next Metrics/AbcSize -- Exercise native failure/change exits and provisioned-state retry.
  def verify_failed_catalog_retry(manifest)
    marker = File.join(project, 'manifests/site.pp')
    [4, 6].each do |status|
      change = status == 6 ? "file { '/tmp/failure-change': content => 'changed' }" : ''
      File.write(marker, manifest + "\nexec { 'catalog-failure': command => '/bin/false' }\n#{change}\n")
      expect { app.nodes.puppet(name: hostname) }.to raise_error(Empeira::Error, /exit #{status}/)
      expect(record.fetch('provisioned')).to be(true)
      expect(guest(%w[id -u]).stdout.strip).to eq('0')
      File.write(marker, manifest)
      expect(app.nodes.puppet(name: hostname).exit_status).to eq(0)
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Verify actual upload contents, ownership and staging cleanup.
  def verify_management_upload
    source = File.join(@directory, 'management-upload')
    File.write(source, 'synthetic root upload')
    destination = '/tmp/empeira-management-upload'
    management_guest.copy_to(record, source, destination, mode: '0600')
    expect(guest(['cat', destination]).stdout).to eq('synthetic root upload')
    expect(guest(['stat', '-c', '%u:%g:%a', destination]).stdout.strip).to eq('0:0:600')
    expect(guest(['find', Empeira::VM::Management::UPLOADS, '-mindepth', '1']).stdout).to be_empty
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

  def wait_for_system_login_exit
    Timeout.timeout(60) do
      loop do
        result = guest(['pgrep', '-u', Empeira::VM::CloudInit::USER])
        return if result.exit_status == 1

        expect(result).to be_success, result.stderr
        sleep 0.2
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
