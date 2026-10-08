# frozen_string_literal: true

require_relative 'support/service_runtime'

RSpec.describe 'Additional service configuration' do
  let(:project) { File.join(@directory, 'control') }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
  let(:service) do
    { 'name' => 'example-api', 'image' => { 'repository' => 'example/api', 'tag' => '1.0' },
      'configuration' => { 'target' => '/etc/example/config.yaml', 'content' => { 'version' => 1 } } }
  end

  before { initialize_project(project) }

  def context(entries = [service])
    File.write(File.join(project, '.empeira.yaml'), YAML.dump('containers' => { 'additional' => entries }))
    Empeira::Application.new(project_path: project, locations: locations).context
  end

  def plan(entries = [service])
    Empeira::ControlPlane::Plan.new(context: context(entries))
  end

  it 'leaves definitions and files unchanged when configuration is absent' do
    current = plan([service.except('configuration')])
    expect(current.additional_services.fetch('example-api').options.keys & %w[configuration mounts]).to be_empty
    current.additional_configurations.prepare
    expect(current.additional_configurations.directory).not_to exist
  end

  [{ 'version' => 1, 'nested' => { 'items' => [true, nil, 2.5, { 'key' => 'value' }] } },
   [1, 'true', false, nil], 'true', 'null', '1.0', '${HOME} {{ value }} <%= system("id") %>',
   42, 1.5, true, false, nil].each do |content|
    it "round-trips #{content.inspect} as literal YAML data" do
      service['configuration']['content'] = content
      current = plan
      current.additional_configurations.prepare
      file = current.additional_configurations.path(service)
      expect(YAML.safe_load_file(file)).to eq(content)
      expect(file.to_s).to start_with("#{locations.workspace(current.context.workspace)}/")
      expect(file.to_s).not_to start_with("#{project}/")
      expect(file.stat.mode & 0o777).to eq(0o644)
      expect(file.parent.stat.mode & 0o777).to eq(0o700)
      expect(current.additional_services.fetch('example-api').options.fetch('mounts'))
        .to eq(["type=bind,src=#{file},dst=/etc/example/config.yaml,readonly"])
      inode = file.stat.ino
      current.additional_configurations.prepare
      expect(file.stat.ino).to eq(inode)
    end
  end

  ['', 'relative.yaml', '/', '/etc/', '/etc/../config', '/etc/./config', '//etc/config', '/etc//config',
   '/config,readonly', "/config\n", "/config\0", '/etc\\config', '/config;command', '/etc/hosts',
   '/etc/resolv.conf', '/etc/hostname', '/etc', '/etc/hosts/child'].each do |target|
    it "rejects unsafe or managed target #{target.inspect}" do
      service['configuration']['target'] = target
      expect { context }.to raise_error(Empeira::ConfigurationError, /containers.additional\[0\].configuration.target/)
    end
  end

  [nil, {}, { 'target' => '/config' }, { 'content' => nil },
   { 'target' => '/config', 'content' => {}, 'source' => '/host/path' }].each do |value|
    it "rejects incomplete or unsupported configuration #{value.inspect}" do
      service['configuration'] = value
      expect { context }.to raise_error(Empeira::ConfigurationError, /containers.additional\[0\].configuration/)
    end
  end

  ['!ruby/object:Object {}', '!!str tagged', '&shared {value: 1}', '*shared'].each do |value|
    it "rejects explicit YAML tags, anchors and aliases: #{value}" do
      text = YAML.dump('containers' => { 'additional' => [service] })
      text = text.sub(/content:\n\s+version: 1/, "content: #{value}")
      File.write(File.join(project, '.empeira.yaml'), text)
      expect { Empeira::Application.new(project_path: project, locations: locations).context }
        .to raise_error(Empeira::ConfigurationError, /tags|aliases|anchors/)
    end
  end

  it 'rejects objects and recursive structures supplied directly to schema validation' do
    recursive = []
    recursive << recursive
    [Object.new, :symbol, recursive, { 'nested' => Object.new }].each do |value|
      service['configuration']['content'] = value
      expect { Empeira::Configuration::AdditionalServices.validate!([service], 'containers.additional') }
        .to raise_error(Empeira::ConfigurationError, /configuration.content/)
    end
  end

  it 'fails closed on equal, ancestor and descendant mount targets and preserves unrelated mounts' do
    current = plan
    %w[/etc/example/config.yaml /etc/example /etc/example/config.yaml/child /].each do |target|
      expect { current.additional_services(mounts: ["type=bind,src=/host/data,dst=#{target},readonly"]) }
        .to raise_error(Empeira::ConfigurationError, /configuration.target overlaps/)
    end
    mount = 'type=bind,src=/host/data,dst=/data,readonly'
    expect(current.additional_services(mounts: [mount]).fetch('example-api').options.fetch('mounts').first).to eq(mount)
  end

  it 'gives services separate files and prunes retired configuration after reconciliation' do
    other = Marshal.load(Marshal.dump(service))
    other['name'] = 'example-other'
    other['configuration']['content'] = [false, 'separate']
    generated = plan([service, other]).additional_configurations
    generated.prepare
    expect(generated.path(service)).not_to eq(generated.path(other))
    expect(YAML.safe_load_file(generated.path(other))).to eq([false, 'separate'])
    plan.additional_configurations.prune
    expect(generated.path(other)).not_to exist
    expect(generated.path(service)).to exist
    plan([]).additional_configurations.cleanup
    expect(generated.directory).not_to exist
  end

  it 'rejects file symlinks without modifying their destination' do
    generated = plan.additional_configurations
    generated.prepare
    outside = File.join(project, 'untouched')
    File.write(outside, 'original')
    generated.path(service).unlink
    File.symlink(outside, generated.path(service))
    expect { generated.prepare }.to raise_error(Empeira::Error, /symlink/)
    expect(File.read(outside)).to eq('original')
  end

  it 'rejects managed directory symlinks during generation and cleanup' do
    generated = plan.additional_configurations
    generated.prepare
    FileUtils.remove_entry_secure(generated.directory)
    File.symlink(project, generated.directory)
    expect { generated.prepare }.to raise_error(Empeira::Error, /symlink/)
    expect { generated.cleanup }.to raise_error(Empeira::Error, /symlink/)
    expect(Pathname(project).join('.empeira.yaml')).to exist
  end

  %i[workspace workspaces state].each do |level|
    it "rejects a symlink at the managed #{level} ancestor" do
      current = plan
      workspace = locations.workspace(current.context.workspace)
      ancestor = { workspace: workspace, workspaces: workspace.parent, state: locations.state }.fetch(level)
      FileUtils.mkdir_p(ancestor.parent)
      File.symlink(project, ancestor)
      expect { current.additional_configurations.prepare }.to raise_error(Empeira::Error, /symlink/)
      expect(Pathname(project).join('additional-configurations')).not_to exist
    end
  end

  it 'keeps the previous file intact and removes temporary files when atomic publication fails' do
    generated = plan.additional_configurations
    generated.prepare
    previous = generated.path(service).binread
    service['configuration']['content'] = { 'version' => 2 }
    changed = plan.additional_configurations
    allow(File).to receive(:rename).and_raise(Errno::EIO)
    expect { changed.prepare }.to raise_error(Errno::EIO)
    expect(generated.path(service).binread).to eq(previous)
    expect(generated.directory.children).to eq([generated.path(service)])
  end

  it 'rejects a workspace placed inside the control repository' do
    allow(locations).to receive(:workspace).and_return(Pathname(project).join('state'))
    expect { plan.additional_configurations.prepare }.to raise_error(Empeira::Error, /outside the control repository/)
    expect(Pathname(project).join('state')).not_to exist
  end

  context 'reconciliation' do
    let(:runtime) { ServiceRuntime.new }
    let(:store) { Empeira::Infrastructure::Store.new(context: context) }

    before do
      current = context
      definition = Empeira::Infrastructure::Definition.new(context: current)
      store.with_lock do
        store.write('peer_network' => { 'subnet' => '172.20.0.0/24' },
                    'schema_version' => 2, 'workspace' => current.workspace.id, 'runtime' => 'podman',
                    'resources' => { 'network' => { 'id' => 'network-id', 'name' => definition.network.backend_name,
                                                    'logical_identity' => definition.network.identity } },
                    'definition' => definition.metadata, 'fingerprint' => definition.fingerprint,
                    'created_at' => Time.now.utc.iso8601, 'reconciled_at' => Time.now.utc.iso8601)
      end
      allow(Empeira::ControlPlane::Health).to receive(:new).and_return(
        instance_double(Empeira::ControlPlane::Health, wait: nil, ready?: true)
      )
      allow(Empeira::Runtime::MountProbe).to receive(:new).and_return(
        instance_double(Empeira::Runtime::MountProbe, verify: nil)
      )
    end

    def mutate(operation, entries = [service])
      controller = Empeira::ControlPlane::Controller.new(context: context(entries), runtime: runtime, store: store)
      store.with_lock { controller.public_send(operation) }
    end

    it 'recreates only the affected service for content/target changes and leaves repeated up idle' do
      mutate(:up)
      %w[content target].each do |field|
        ids = runtime.services.transform_values { |resource| resource.fetch('id') }
        expect(mutate(:up)).to be(false)
        expect(runtime.services.transform_values { |resource| resource.fetch('id') }).to eq(ids)
        service['configuration'][field] = field == 'content' ? { 'version' => 2 } : '/config/updated.yaml'
        expect(mutate(:up)).to be(true)
        expect(runtime.services.fetch('example-api').fetch('id')).not_to eq(ids.fetch('example-api'))
        expect(runtime.services.except('example-api').transform_values { |resource| resource.fetch('id') })
          .to eq(ids.except('example-api'))
        expect(YAML.safe_load_file(plan.additional_configurations.path(service)))
          .to eq(service.dig('configuration', 'content'))
      end
      expect(mutate(:up)).to be(false)
    end

    it 'retains files across down/up and removes them on destroy even after removing the definition' do
      mutate(:up)
      generated = plan.additional_configurations
      mutate(:down)
      expect(generated.path(service)).to exist
      mutate(:up)
      expect(YAML.safe_load_file(generated.path(service))).to eq('version' => 1)
      mutate(:destroy, [])
      expect(generated.directory).not_to exist
    end

    it 'removes a retired mount and its file only after recreating the service' do
      mutate(:up)
      generated = plan.additional_configurations
      previous = runtime.services.fetch('example-api').fetch('id')
      mutate(:up, [service.except('configuration')])
      expect(runtime.services.fetch('example-api').fetch('id')).not_to eq(previous)
      expect(generated.path(service)).not_to exist
    end

    it 'retains retired files when replacement fails' do
      mutate(:up)
      generated = plan.additional_configurations
      runtime.failure = 'example-api'
      expect { mutate(:up, [service.except('configuration')]) }.to raise_error(Empeira::Providers::ExecutionError)
      expect(generated.path(service)).to exist
    end
  end
end
