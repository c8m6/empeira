# frozen_string_literal: true

require_relative 'support/service_runtime'
require_relative 'support/command_mock_guest'

class NodeRuntimeFixture < ServiceRuntime
  attr_accessor :agent_exit

  def check_available!; end

  def architecture
    'amd64'
  end

  def image_architecture(_image)
    architecture
  end

  def ssh_proxy_command(resource)
    ['ruby', 'managed-ssh-proxy', 'docker', resource.fetch('id')]
  end

  def stop_service(resource)
    resource['state'] = 'exited'
  end

  def stream_service(_resource, _arguments, **)
    calls << [:puppet]
    Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: agent_exit || 0, timed_out: false)
  end
end

RSpec.describe Empeira::Node::Container do
  include CommandMockGuest

  let(:runtime) { NodeRuntimeFixture.new }
  let(:app) do
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
  let(:provider) { described_class.new(context: app.context, runner: app.runner, backend: runtime) }
  let(:request) do
    Empeira::Node::RunRequest.from_config(hostname: 'test-node', provider: 'container',
                                          config: app.context.configuration)
  end

  before do
    allow(Empeira::Node::AgentInstallation).to receive(:new).and_return(
      instance_double(Empeira::Node::AgentInstallation, install: nil)
    )
    definition = Empeira::Infrastructure::Definition.new(context: app.context)
    runtime.networks[definition.network.backend_name] = Empeira::Network::Resource.new(
      id: 'network-id', name: definition.network.backend_name, labels: definition.network.labels,
      isolated: true, attachment_count: 0
    )
    store.with_lock do
      store.write('schema_version' => 2, 'workspace' => app.context.workspace.id, 'runtime' => 'podman',
                  'resources' => { 'network' => { 'id' => 'network-id', 'name' => definition.network.backend_name,
                                                  'logical_identity' => definition.network.identity } },
                  'definition' => definition.metadata, 'fingerprint' => definition.fingerprint,
                  'component_fingerprints' => definition.component_fingerprints,
                  'peer_network' => { 'subnet' => '10.203.20.0/24' },
                  'created_at' => Time.now.utc.iso8601, 'reconciled_at' => Time.now.utc.iso8601)
      allow(Empeira::ControlPlane::Health).to receive(:new).and_return(
        instance_double(Empeira::ControlPlane::Health, wait: nil, ready?: true)
      )
      allow(Empeira::Runtime::MountProbe).to receive(:new).and_return(
        instance_double(Empeira::Runtime::MountProbe, verify: nil)
      )
      Empeira::ControlPlane::Controller.new(context: app.context, runtime: runtime, store: store).up
    end
    certificates = instance_double(Empeira::Node::Certificates, clean: nil)
    allow(certificates).to receive(:enroll) do |_resource, record, &persist|
      record['certificate_key'] = 'a' * 64
      persist.call
    end
    allow(Empeira::Node::Certificates).to receive(:new).and_return(certificates)
  end

  context 'with the normal workspace proxy enabled' do
    let(:app) do
      File.write(File.join(@directory, '.empeira.yaml'),
                 YAML.dump('proxy' => { 'enabled' => true, 'global' => ['packages.example'] }))
      Empeira::Application.new(project_path: @directory,
                               locations: Empeira::Platform::Locations.new(
                                 home: File.join(@directory, 'user-home'), environment: {}
                               ))
    end

    it 'configures every new container node for the normal proxy without a per-node switch' do
      provider.run(request)
      record = store.load.fetch('nodes').fetch('test-node')
      expect(record).not_to have_key('internet')
      expect(record.dig('definition', 'environment')).to include(
        'HTTP_PROXY' => 'http://proxy.empeira.internal:3128',
        'HTTPS_PROXY' => 'http://proxy.empeira.internal:3128'
      )
    end
  end

  context 'with the managed agent repository' do
    let(:app) do
      config = { 'bootstrap' => { 'packages' => { 'install' => { 'default' => ['git'] } } } }
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
      super()
    end

    it 'leaves credential handling to agent acquisition' do
      ENV['EMPEIRA_AGENT_REPO_USERNAME'] = 'incomplete-user'
      provider.run(request)
      expect(store.load.dig('nodes', 'test-node', 'provisioned')).to be(true)
    end

    it 'installs base packages, then the agent, then configures and runs Puppet' do
      events = []
      installer = instance_double(Empeira::Node::AgentInstallation)
      allow(Empeira::Node::AgentInstallation).to receive(:new).and_return(installer)
      allow(installer).to receive(:install) { events << :agent }
      allow(runtime).to receive(:service_exec).and_wrap_original do |method, resource, arguments, **options|
        events << :base_packages if arguments.first == 'apt-get' && arguments.include?('git')
        events << :configure if arguments.first == Empeira::Node::Certificates::PUPPET &&
                                arguments.include?('config')
        method.call(resource, arguments, **options)
      end
      allow(runtime).to receive(:stream_service).and_wrap_original do |method, *arguments, **options|
        events << :puppet
        method.call(*arguments, **options)
      end

      provider.run(request)
      expect(events.uniq.first(4)).to eq(%i[base_packages agent configure puppet])
      expect(store.load.fetch('nodes').fetch('test-node').fetch('network_phase')).to eq('runtime')
    end

    it 'retains the node and never runs Puppet when agent installation fails' do
      installer = instance_double(Empeira::Node::AgentInstallation)
      allow(Empeira::Node::AgentInstallation).to receive(:new).and_return(installer)
      allow(installer).to receive(:install).and_raise(Empeira::Error, 'repository authentication failed')
      expect(runtime).not_to receive(:stream_service)
      expect { provider.run(request) }.to raise_error(Empeira::Error, /repository authentication failed/)
      expect(store.load.dig('nodes', 'test-node', 'id')).not_to be_nil
      expect(store.load).not_to have_key('bootstrap_proxy')
    end

    it 'uses DNF after base package bootstrap on a Rocky container' do
      events = []
      installer = instance_double(Empeira::Node::AgentInstallation, install: nil)
      expect(Empeira::Node::AgentInstallation).to receive(:new).and_return(installer)
      expect(installer).to receive(:install) { events << :agent }
      allow(runtime).to receive(:service_exec).and_wrap_original do |method, resource, arguments, **options|
        events << :base_packages if arguments.first == 'dnf' && arguments.include?('git')
        method.call(resource, arguments, **options)
      end
      provider.run(request.with(os: 'rocky', version: '9'))
      expect(events).to eq(%i[base_packages agent])
    end
  end

  %i[installation restoration proxy configuration enrollment].each do |stage|
    it "blocks subsequent Puppet and start after #{stage} failure while retaining diagnostic access" do
      case stage
      when :installation
        allow(provider).to receive(:install_agent).and_raise(Empeira::Error, 'installation failed')
      when :restoration
        allow_any_instance_of(Empeira::Node::AptConfiguration).to receive(:preserve) do |_, &operation|
          operation.call
          raise Empeira::Error, 'restoration failed'
        end
      when :proxy
        allow(provider.instance_variable_get(:@bootstrap_proxy)).to receive(:cleanup).and_raise(Empeira::Error,
                                                                                                'cleanup failed')
      when :configuration
        allow(provider).to receive(:configure).and_raise(Empeira::Error, 'configuration failed')
      when :enrollment
        certificates = instance_double(Empeira::Node::Certificates)
        allow(certificates).to receive(:enroll).and_raise(Empeira::Error, 'enrollment failed')
        allow(Empeira::Node::Certificates).to receive(:new).and_return(certificates)
      end
      expect { provider.run(request) }.to raise_error(Empeira::Error, /failed/)
      expect(store.load.dig('nodes', request.hostname, 'provisioned')).to be(false)
      expect(provider.list.first['state']).to eq('incomplete')
      expect { provider.start(name: request.hostname) }.to raise_error(Empeira::Error, /incomplete/)
      expect { provider.puppet(name: request.hostname) }.to raise_error(Empeira::Error, /incomplete/)
      expect(runtime.calls).not_to include([:puppet])
      expect { provider.shell(name: request.hostname) }.not_to raise_error
    end
  end

  it 'allows retry after a failed first catalog because provisioning and cleanup already succeeded' do
    runtime.agent_exit = 7
    expect { provider.run(request) }.to raise_error(Empeira::Error, /Puppet agent failed/)
    expect(store.load.dig('nodes', request.hostname, 'provisioned')).to be(true)
    runtime.agent_exit = 0
    expect(provider.puppet(name: request.hostname).exit_status).to eq(0)
  end

  it 'selects packages, distribution repositories and grants using node architecture instead of host architecture' do
    allow(runtime).to receive(:architecture).and_return('arm64')
    packages = { 'ubuntu24.04' => %w[amd64 arm64].to_h do |architecture|
      [architecture, { 'url' => "https://packages.example.net/#{architecture}.deb", 'sha256' => 'a' * 64 }]
    end }
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('agent' => { 'install' => { 'method' => 'package', 'packages' => packages } }))
    host = Empeira::Platform::Facts.new(host_os: 'linux', host_cpu: 'x86_64')
    context = Empeira::Application.new(project_path: @directory, platform: host).context
    expect(context.platform.architecture).not_to eq(runtime.architecture)
    container = described_class.new(context: context, runner: app.runner, backend: runtime)
    record = { 'os' => 'ubuntu', 'version' => '24.04', 'architecture' => runtime.architecture }
    requirements = container.send(:package_requirements, record, agent_required: true)
    expect(requirements.repository.fetch('url')).to end_with('/arm64.deb')
    expect(requirements.destinations).to include('ports.ubuntu.com')
    expect(requirements.destinations).not_to include('archive.ubuntu.com', 'security.ubuntu.com')
    rocky = container.send(:package_requirements, record.merge('os' => 'rocky', 'version' => '9'))
    expect(rocky.rpm_options.join(' ')).to include('/aarch64/os/')
  end

  context 'with project server mounts' do
    let(:app) do
      File.write(File.join(@directory, 'artifact.txt'), 'fixture')
      mount = { 'source' => 'artifact.txt', 'target' => '/srv/server-only.txt' }
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('server' => { 'mounts' => [mount] }))
      super()
    end

    it 'does not forward server bind mounts to container nodes' do
      node_seen = false
      allow(runtime).to receive(:create_service).and_wrap_original do |original, definition|
        if definition.options['hostname'] == 'test-node'
          expect(definition.options.fetch('mounts', [])).to be_empty
          node_seen = true
        end
        original.call(definition)
      end
      provider.run(request)
      expect(node_seen).to be(true)
    end
  end

  context 'with global bootstrap packages' do
    let(:app) do
      packages = {
        'install' => { 'default' => ['git'], 'debian' => ['libxml2-dev'] },
        'remove' => { 'default' => ['telnet'] }
      }
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('bootstrap' => { 'packages' => packages }))
      super()
    end

    it 'runs once before the first Puppet catalog and runs again only for a new instance' do
      provider.run(request)
      package_calls = runtime.calls.select { |call| call.first == :exec && %w[apt-get dnf].include?(call.last.first) }
      expect(package_calls.map(&:last)).to include(
        array_including('remove', 'telnet'), array_including('install', 'git', 'libxml2-dev')
      )
      expect(runtime.calls.index(package_calls.last)).to be < runtime.calls.index([:puppet])
      first_count = package_calls.size

      provider.puppet(name: request.hostname)
      store.with_lock do
        Empeira::ControlPlane::Controller.new(context: app.context, runtime: runtime, store: store).up
      end
      provider.stop(name: request.hostname)
      provider.start(name: request.hostname)
      expect(runtime.calls.count { |call| call.first == :exec && call.last.first == 'apt-get' }).to eq(first_count)

      provider.destroy(name: request.hostname)
      provider.run(request)
      expect(runtime.calls.count { |call| call.first == :exec && call.last.first == 'apt-get' }).to eq(first_count * 2)
    end

    it 'does not start Puppet after a package-manager failure' do
      failure = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 100, timed_out: false)
      allow(runtime).to receive(:service_exec).and_wrap_original do |original, resource, arguments, **options|
        next failure if arguments.first == 'apt-get'

        original.call(resource, arguments, **options)
      end
      expect(runtime).not_to receive(:stream_service)
      expect { provider.run(request) }.to raise_error(Empeira::Error, /Package bootstrap remove failed/)
    end
  end

  it 'reserves identity atomically, rejects duplicates and preserves container state through stop/start' do
    expect(provider.run(request)).to have_attributes(changed: true)
    expect(provider).to be_a(Empeira::Node::Interface)
    expect(provider.name).to eq('container')
    expect(provider.inspect_resource(name: 'TEST-node')).to have_attributes(name: 'test-node', state: :running)
    identity = store.load.dig('nodes', 'test-node', 'id')
    expect { provider.run(request) }.to raise_error(Empeira::Providers::AlreadyExists)
    expect(provider.stop(name: 'test-node').changed).to be(true)
    expect(provider.stop(name: 'test-node').changed).to be(false)
    expect(provider.list.first).to include('state' => 'stopped')
    expect(provider.list.first).not_to have_key('internet')
    expect(provider.inspect_resource(name: 'test-node').state).to eq(:stopped)
    provider.start(name: 'test-node')
    expect(store.load.dig('nodes', 'test-node', 'id')).to eq(identity)
    expect(provider.destroy(name: 'test-node').changed).to be(true)
    expect(provider.destroy(name: 'test-node').changed).to be(false)
    expect(provider.list).to be_empty
    provider.run(request)
    expect(store.load.dig('nodes', 'test-node', 'id')).not_to eq(identity)
  end

  it 'persists SSH details, keeps runtime shell distinct, rejects stopped access and cleans up keys' do
    provider.run(request)
    record = store.load.fetch('nodes').fetch('test-node')
    expect(record).to include('ssh_host' => '127.0.0.1', 'ssh_port' => 32_124, 'ssh_transport' => 'loopback')
    client = instance_double(Empeira::Node::UserSSH, session: runtime.stream_service(nil, []))
    allow(Empeira::Node::UserSSH).to receive(:new).and_return(client)
    expect(client).to receive(:session).with(hash_including('id' => record['id']), user: nil, identity: nil)
    provider.ssh(name: 'test-node')
    expect(runtime).to receive(:stream_service).with(hash_including('id' => record['id']), ['/bin/bash'],
                                                     interactive: true)
    provider.shell(name: 'test-node')
    provider.stop(name: 'test-node')
    expect { provider.ssh(name: 'test-node') }.to raise_error(Empeira::Error, /empeira node start test-node/)
    provider.destroy(name: 'test-node')
    path = app.context.locations.workspace(app.context.workspace).join('containers', 'test-node')
    expect(path).not_to exist
  end

  it 'keeps failed Puppet results separate from running container state' do
    runtime.agent_exit = 6
    expect { provider.run(request) }.to raise_error(Empeira::Error, /Puppet agent failed/)
    expect(provider.list.first).to include('state' => 'running', 'last_puppet_exit' => 6)
    runtime.agent_exit = 2
    expect(provider.puppet(name: 'test-node').exit_status).to eq(2)
  end

  it 'refuses a stale catalog when cache invalidation fails after a code edit' do
    provider.run(request)
    File.write(File.join(@directory, 'hiera.yaml'), 'changed')
    failure = Empeira::Execution::Result.new(stdout: '403', stderr: '', exit_status: 22, timed_out: false)
    allow(runtime).to receive(:service_exec).with(anything, array_including('DELETE'), timeout: 15).and_return(failure)
    expect(runtime).not_to receive(:stream_service)
    expect { provider.puppet(name: request.hostname) }.to raise_error(Empeira::Error, /invalidation failed/)
  end

  it 'stops before certificate enrollment and Puppet when distribution sources are unavailable' do
    expect(Empeira::Node::PackageSources).to receive(:verify!).and_raise(Empeira::Error, 'APT sources unavailable')
    expect(runtime).not_to receive(:stream_service)
    expect { provider.run(request) }.to raise_error(Empeira::Error, /APT sources unavailable/)
    expect(store.load.dig('nodes', request.hostname, 'id')).not_to be_nil
  end

  it 'stops before the first catalog when the external fact cannot be installed' do
    expect_any_instance_of(Empeira::Node::ContainerBootstrap).to receive(:apply)
      .and_raise(Empeira::Error, 'bootstrap failed; Puppet was not run')
    expect(runtime).not_to receive(:stream_service)
    expect { provider.run(request) }.to raise_error(Empeira::Error, /bootstrap failed; Puppet was not run/)
  end

  it 'verifies shared bootstrap state before enrollment and the first Puppet run' do
    certificates = Empeira::Node::Certificates.new
    bootstrap = Empeira::Node::ContainerBootstrap.new(runtime: runtime)
    allow(Empeira::Node::ContainerBootstrap).to receive(:new).and_return(bootstrap)
    expect(bootstrap).to receive(:apply).ordered.and_call_original
    expect(certificates).to receive(:enroll).ordered do |_resource, record, &persist|
      record['certificate_key'] = 'a' * 64
      persist.call
    end
    expect(runtime).to receive(:stream_service).ordered.and_call_original
    provider.run(request)
  end

  it 'uses a real SSH client over a scoped byte tunnel when internal networks cannot publish ports' do
    allow(runtime).to receive(:node_ssh_publication?).and_return(false)
    provider.run(request)
    record = store.load.fetch('nodes').fetch('test-node')
    expect(record).to include('ssh_host' => '127.0.0.1', 'ssh_port' => 22, 'ssh_transport' => 'tunnel')
    expect(record.fetch('definition').fetch('ports')).to be_empty
    client = instance_double(Empeira::Node::UserSSH)
    expect(Empeira::Node::UserSSH).to receive(:new).with(
      runner: app.runner, credentials: an_instance_of(Empeira::Node::SSHCredentials),
      home: app.context.locations.home,
      proxy_command: ['ruby', 'managed-ssh-proxy', 'docker', record.fetch('id')]
    ).and_return(client)
    expect(client).to receive(:session).with(hash_including('id' => record.fetch('id')), user: nil, identity: nil)
    provider.ssh(name: 'test-node')
  end

  it 'retains an uncertain creation reservation until explicit cleanup' do
    runtime.failure = Empeira::Node::Definition.new(hostname: request.hostname, workspace: app.context.workspace).key
    expect { provider.run(request) }.to raise_error(Empeira::Providers::ExecutionError)
    expect(store.load.fetch('nodes')).to have_key('test-node')
    expect { provider.run(request) }.to raise_error(Empeira::Providers::AlreadyExists)
    runtime.failure = nil
    provider.destroy(name: 'test-node')
    expect(provider.list).to be_empty
  end

  it 'refuses ownership conflicts and unexpected network attachments before mutation' do
    provider.run(request)
    resource = runtime.services.values.find { |item| item.dig('labels', 'io.empeira.purpose') == 'node' }
    resource['networks']['foreign-egress'] = { 'IPAddress' => '192.0.2.1' }
    expect { provider.stop(name: 'test-node') }.to raise_error(Empeira::Providers::OwnershipError)
    resource['networks'].delete('foreign-egress')
    resource['id'] = 'unexpected-replacement'
    expect { provider.destroy(name: 'test-node') }.to raise_error(Empeira::Providers::OwnershipError)
    expect(store.load.fetch('nodes')).to have_key('test-node')
  end

  it 'reports missing and stale nodes without recreating them' do
    provider.run(request)
    definition = Empeira::Node::Definition.new(hostname: request.hostname, workspace: app.context.workspace)
    resource = runtime.services.fetch(definition.key)
    resource['labels']['io.empeira.definition'] = 'changed'
    expect(provider.list.first['state']).to eq('stale')
    runtime.services.delete(definition.key)
    expect(provider.list.first['state']).to eq('missing')
    expect(provider.inspect_resource(name: 'test-node')).to be_nil
  end

  it 'rejects reserved service identities without reserving a node' do
    %w[server server.empeira.internal].each do |hostname|
      expect { provider.run(request.with(hostname: hostname)) }.to raise_error(Empeira::Providers::AlreadyExists)
    end
    expect(store.load.fetch('nodes', {})).to be_empty
  end

  it 'does not emulate a foreign image architecture' do
    allow(runtime).to receive(:image_architecture).and_return('arm64')
    expect { provider.run(request) }.to raise_error(Empeira::Error, /architecture differs/)
    expect(store.load.dig('nodes', 'test-node', 'id')).to be_nil
  end

  it 'refuses node creation when the workspace network has lost isolation' do
    network = Empeira::Infrastructure::Definition.new(context: app.context).network
    runtime.networks[network.backend_name] = Empeira::Network::Resource.new(
      id: 'network-id', name: network.backend_name, labels: network.labels, isolated: false, attachment_count: 0
    )
    expect { provider.run(request) }.to raise_error(Empeira::Network::UnsupportedPolicy)
    expect(store.load.fetch('nodes', {})).to be_empty
  end

  it 'fails closed on malformed persisted node ownership' do
    provider.run(request)
    data = store.load
    expect { store.write(data.merge('nodes' => nil)) }.to raise_error(Empeira::Infrastructure::StateError)
    data['nodes']['test-node']['hostname'] = 'different'
    expect { store.write(data) }.to raise_error(Empeira::Infrastructure::StateError)
  end

  it 'installs mocks before Puppet and reconciles running and stopped nodes through the existing inventory' do
    execute_guest_mocks(runtime, :service_exec)
    context = mock_context('oc' => mock_definition)
    node = described_class.new(context: context, runner: app.runner, backend: runtime)
    expect(runtime).to receive(:stream_service).and_wrap_original do |method, *arguments|
      expect(File.executable?(mock_definition['path'])).to be(true)
      method.call(*arguments)
    end
    node.run(request)
    identity = store.load.dig('nodes', 'test-node', 'id')
    expect(node.start(name: 'test-node').changed).to be(false)
    store.with_lock { expect(node.reconcile_all(state: store.load)).to be(false) }
    File.write(mock_definition['path'], 'installed command')
    store.with_lock { expect(node.reconcile_all(state: store.load)).to be(true) }
    expect(app.runner.run(mock_definition['path']).stdout).to eq("oc\n")

    node.stop(name: 'test-node')
    changed = mock_definition.merge('exit_code' => 17)
    updated = described_class.new(context: mock_context('oc' => changed), runner: app.runner, backend: runtime)
    store.with_lock { expect(updated.reconcile_all(state: store.load)).to be(false) }
    expect(updated.start(name: 'test-node').changed).to be(true)
    expect(app.runner.run(changed['path']).exit_status).to eq(17)
    expect(store.load.dig('nodes', 'test-node', 'id')).to eq(identity)

    removed = described_class.new(context: mock_context({}), runner: app.runner, backend: runtime)
    store.with_lock { expect(removed.reconcile_all(state: store.load)).to be(true) }
    expect(File.exist?(changed['path'])).to be(false)
    expect(store.load.dig('nodes', 'test-node', 'command_mocks')).to eq({})
  end

  it 'replaces a pre-existing command before Puppet and rejects tampered mock inventory' do
    execute_guest_mocks(runtime, :service_exec)
    context = mock_context('oc' => mock_definition)
    FileUtils.mkdir_p(File.dirname(mock_definition['path']))
    File.write(mock_definition['path'], 'foreign')
    expect(runtime).to receive(:stream_service).and_wrap_original do |method, *arguments|
      expect(File.read(mock_definition['path'])).not_to eq('foreign')
      method.call(*arguments)
    end
    node = described_class.new(context: context, runner: app.runner, backend: runtime)
    node.run(request)
    expect(app.runner.run(mock_definition['path']).stdout).to eq("oc\n")
    data = store.load
    data['nodes']['test-node']['command_mocks'][mock_definition['path']]['fingerprint'] = 'tampered'
    expect { store.write(data) }.to raise_error(Empeira::Infrastructure::StateError)
  end
end

RSpec.describe 'Container SSH lifecycle' do
  # The shared fixture exercises actual inventory and ownership transactions.
  it 'rejects arbitrary publications even when they advertise SSH' do
    record = { 'ssh_host' => '127.0.0.1', 'ssh_transport' => 'loopback', 'ssh_port' => 32_123,
               'definition' => { 'ports' => ['127.0.0.1::22/tcp'] } }
    bindings = [{ 'HostIp' => '127.0.0.1', 'HostPort' => '32123' }]
    resource = { 'state' => 'running', 'ports' => { '22/tcp' => bindings },
                 'published_ports' => { '22/tcp' => bindings, '80/tcp' => bindings } }
    expect(Empeira::Node::SSHEndpoint.valid?(resource, record)).to be(false)
  end
end
