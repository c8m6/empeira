# frozen_string_literal: true

require_relative '../support/node_access'
require_relative '../support/login_fixture'
require_relative '../support/console_login'
require_relative '../support/personal_ssh'

RSpec.describe 'Real accelerated VM nodes', :integration do
  include LiveNodeAccess
  include LiveConsoleLogin
  include LivePersonalSSH

  let(:engine_name) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') }) }
  let(:project) { File.join(@directory, 'control') }
  let(:app) do
    Empeira::Application.new(project_path: project, locations: locations,
                             overrides: { 'runtime' => { 'container_engine' => engine_name } })
  end

  before do
    skip 'Set EMPEIRA_VM_INTEGRATION=1 for a real hardware-accelerated VM' unless ENV['EMPEIRA_VM_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    config = { 'puppetdb' => { 'enabled' => false }, 'vm' => { 'disk' => 32 },
               'bootstrap' => { 'packages' => { 'install' => { 'default' => ['git'] } } } }
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
    @login = LoginFixture.new(directory: @directory)
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      #{@login.manifest}
      notify { 'vm-agent-communication': }
      file { '/tmp/empeira-provider': content => $facts['empeira']['provider'] }
    PUPPET
    Empeira::Runtime.registry.build(engine_name, context: app.context, runner: app.runner).check_available!
    qemu = Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner)
    qemu.preflight!
  end

  after do
    next unless ENV['EMPEIRA_VM_INTEGRATION'] == '1' && File.directory?(project)

    store = Empeira::Infrastructure::Store.new(context: app.context)
    app.infrastructure.destroy if store.load
  end

  it 'boots, enrolls, reruns Puppet, preserves its disk, and releases its hostname' do
    personal = personal_ssh_application(app, locations: locations, login: @login, pattern: 'vm-*')
    personal.infrastructure.up
    personal.run_node(hostname: 'vm-node', provider: 'vm')
    vm_record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('vm-node')
    expect(JSON.generate(vm_record)).not_to include('lab-key', 'unconfigured-login', @login.identity.to_s)
    verify_disk_capacity(vm_record)
    expect(management_guest.run(vm_record, %w[git --version])).to be_success
    expect(management_guest.run(vm_record, %w[cat /tmp/empeira-provider]).stdout).to eq('vm')
    expect(management_guest.run(vm_record, ['cat', Empeira::Node::ExternalFact::PATH]).stdout)
      .to eq(Empeira::Node::ExternalFact.content('vm'))
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'provider' => 'vm', 'state' => 'running'))
    expect { app.run_node(hostname: 'vm-node', provider: 'container') }
      .to raise_error(Empeira::Providers::AlreadyExists)
    expect([0, 2]).to include(app.nodes.puppet(name: 'vm-node').exit_status)
    verify_ssh_session(app, name: 'vm-node', user: 'empeira')
    verify_ssh_session(app, name: 'vm-node', user: @login.username, identity: @login.identity,
                            override_user: @login.username)
    verify_personal_ssh_sessions(personal, name: 'vm-node', login: @login)
    managed = Empeira::Node::SSHCredentials.new(context: app.context, runner: app.runner, provider: 'vm',
                                                hostname: 'vm-node')
    verify_ssh_session(personal, name: 'vm-node', user: 'empeira', identity: managed.key_path, override_user: 'empeira')
    expect([0, 2]).to include(personal.nodes.puppet(name: 'vm-node').exit_status)
    verify_final_isolation
    management = management_guest
    record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('vm-node')
    expect(management.run(record, %w[systemctl stop ssh.socket ssh.service])).to be_success
    verify_console_login(app, name: 'vm-node')

    app.nodes.stop(name: 'vm-node')
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'state' => 'stopped'))
    marker = File.join(project, '.empeira.yaml')
    configuration = YAML.safe_load_file(marker)
    configuration['vm']['disk'] = 48
    File.write(marker, YAML.dump(configuration))
    changed_app = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine_name } })
    changed_app.infrastructure.up
    changed_app.nodes.start(name: 'vm-node')
    record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('vm-node')
    verify_disk_capacity(record)
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'state' => 'running'))
    expect(management.run(record, %w[id -u]).stdout.strip).to eq('0')
    expect(management.run(record, ['sh', '-c',
                                   'case "$(getent shadow root | cut -d : -f 2)" in ' \
                                   '\!*|\**) exit 0;; *) exit 1;; esac'])).to be_success
    app.nodes.destroy(name: 'vm-node')
    expect(app.nodes.list).to be_empty
  end

  it 'keeps failed APT cleanup diagnosable through VirtIO management and configured console access' do
    app.infrastructure.up
    allow(Empeira::VM::Guest).to receive(:new).and_wrap_original do |constructor, **options|
      constructor.call(**options).tap do |ssh|
        allow(ssh).to receive(:run).and_wrap_original do |original, record, arguments, **arguments_options|
          if arguments == ['rm', '--force', '--', Empeira::Node::AptConfiguration::BACKUP]
            arguments = ['sh', '-c', 'printf "synthetic permanent cleanup failure\\n" >&2; exit 1']
          end
          original.call(record, arguments, **arguments_options)
        end
      end
    end
    expect { app.run_node(hostname: 'incomplete-vm', provider: 'vm') }
      .to raise_error(Empeira::Error, /Cannot remove.*Exit code: 1.*synthetic permanent cleanup failure/m)
    store = Empeira::Infrastructure::Store.new(context: app.context)
    state = store.load
    record = state.fetch('nodes').fetch('incomplete-vm')
    expect(record['provisioned']).to be(false)
    expect(record['network_phase']).to eq('bootstrap')
    expect(record['last_puppet_exit']).to be_nil
    expect(state).not_to have_key('bootstrap_proxy')
    expect(management_guest.run(record, ['tar', '--compare', '--file', Empeira::Node::AptConfiguration::BACKUP,
                                         '--directory', '/'])).to be_success
    verify_ssh_session(app, name: 'incomplete-vm', user: 'empeira')
    allow(app.runner).to receive(:console).and_wrap_original do |original, path, **options|
      expect { store.with_lock { nil } }.not_to raise_error
      expect(app.nodes.list).to include(hash_including('hostname' => 'incomplete-vm', 'state' => 'incomplete'))
      expect { app.nodes.stop(name: 'incomplete-vm') }.to raise_error(Empeira::Infrastructure::Locked)
      input = Tempfile.new('console-detach')
      input.write("\x1d")
      input.rewind
      output = Tempfile.new('console-output')
      original.call(path, **options, input: input, output: output)
    ensure
      input&.close!
      output&.close!
    end
    expect(app.nodes.shell(name: 'incomplete-vm')).to be_success
    allow(app.runner).to receive(:console).and_call_original
    expect { app.nodes.puppet(name: 'incomplete-vm') }.to raise_error(Empeira::Error, /bootstrap is incomplete/)
    app.nodes.destroy(name: 'incomplete-vm')
  end

  def management_guest
    vm_guest(app)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Observe virtual, allocated and guest capacities in one real VM gate.
  def verify_disk_capacity(record)
    root = app.context.locations.workspace(app.context.workspace)
    overlay = root.join(record.fetch('overlay'))
    engine = Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner)
    result = app.runner.run(engine.image_tool, arguments: ['info', '--force-share', '--output=json', overlay.to_s])
    expect(result).to be_success
    metadata = JSON.parse(result.stdout)
    expect(metadata['virtual-size']).to eq(32 * Empeira::VM::Disk::GIB)
    expect(Digest::SHA256.file(metadata.fetch('backing-filename')).hexdigest)
      .to eq(record.fetch('base_image').fetch('checksum'))
    allocated = File.stat(overlay).blocks * 512
    expect(allocated).to be < 8 * Empeira::VM::Disk::GIB
    Empeira::VM::RootDisk.new(guest: management_guest).verify!(record, size_gib: 32)
    usage = management_guest.run(record, %w[df -h /])
    expect(usage).to be_success
    RSpec.configuration.reporter.message(
      "VM disk (#{engine_name}, allocated #{allocated} bytes): #{usage.stdout.strip}"
    )
  end

  # rubocop:disable-next Metrics/AbcSize -- Verify the final inventory and both guest egress paths together.
  def verify_final_isolation
    state = Empeira::Infrastructure::Store.new(context: app.context).load
    expect(state).not_to have_key('bootstrap_proxy')
    record = state.fetch('nodes').fetch('vm-node')
    expect(record).not_to have_key('internet')
    ssh = vm_guest(app)
    %w[http://proxy.empeira.internal:3128].each do |proxy|
      expect(ssh.run(record, ['curl', '--fail', '--max-time', '3', '--proxy', proxy,
                              'https://apt.voxpupuli.org'])).not_to be_success
    end
    expect(ssh.run(record, %w[curl --fail --max-time 3 --noproxy * http://1.1.1.1])).not_to be_success
  end
end
