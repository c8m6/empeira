# frozen_string_literal: true

require_relative '../support/node_access'
require_relative '../support/login_fixture'
require_relative '../support/console_login'

RSpec.describe 'Real accelerated VM nodes', :integration do
  include LiveNodeAccess
  include LiveConsoleLogin

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
    config = { 'puppetdb' => { 'enabled' => false } }
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
    app.infrastructure.up
    app.run_node(hostname: 'vm-node', provider: 'vm')
    vm_record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('vm-node')
    expect(management_ssh.run(vm_record, %w[cat /tmp/empeira-provider]).stdout).to eq('vm')
    expect(management_ssh.run(vm_record, ['cat', Empeira::Node::ExternalFact::PATH]).stdout)
      .to eq(Empeira::Node::ExternalFact.content('vm'))
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'provider' => 'vm', 'state' => 'running'))
    expect { app.run_node(hostname: 'vm-node', provider: 'container') }
      .to raise_error(Empeira::Providers::AlreadyExists)
    expect([0, 2]).to include(app.nodes.puppet(name: 'vm-node').exit_status)
    verify_ssh_session(app, name: 'vm-node', user: @login.username, identity: @login.identity)
    verify_final_isolation
    management = management_ssh
    record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch('vm-node')
    expect(management.run(record, %w[systemctl stop ssh.socket ssh.service])).to be_success
    verify_console_login(app, name: 'vm-node')

    app.nodes.stop(name: 'vm-node')
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'state' => 'stopped'))
    app.nodes.start(name: 'vm-node')
    expect(app.nodes.list).to include(hash_including('hostname' => 'vm-node', 'state' => 'running'))
    expect(management.run(record, %w[passwd -S root]).stdout).to match(/^root L /)
    app.nodes.destroy(name: 'vm-node')
    expect(app.nodes.list).to be_empty
  end

  def management_ssh
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
  end

  # rubocop:disable-next Metrics/AbcSize -- Verify the final inventory and both guest egress paths together.
  def verify_final_isolation
    state = Empeira::Infrastructure::Store.new(context: app.context).load
    expect(state).not_to have_key('bootstrap_proxy')
    record = state.fetch('nodes').fetch('vm-node')
    expect(record).not_to have_key('internet')
    cloud = Empeira::VM::CloudInit.new(context: app.context, runner: app.runner)
    ssh = Empeira::VM::SSH.new(context: app.context, runner: app.runner, cloud_init: cloud)
    %w[http://proxy.empeira.internal:3128].each do |proxy|
      expect(ssh.run(record, ['curl', '--fail', '--max-time', '3', '--proxy', proxy,
                              'https://apt.voxpupuli.org'])).not_to be_success
    end
    expect(ssh.run(record, %w[curl --fail --max-time 3 --noproxy * http://1.1.1.1])).not_to be_success
  end
end
