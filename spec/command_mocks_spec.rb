# frozen_string_literal: true

RSpec.describe Empeira::Node::CommandMocks do
  let(:runner) { Empeira::Execution::Runner.new }
  let(:path) { File.join(@directory, 'bin', 'oc') }
  let(:definition) { { 'path' => path, 'mock_to' => 'echo', 'exit_code' => 0 } }
  let(:commands) { { 'oc' => definition } }
  let(:record) { { 'hostname' => 'test-node', 'provider' => 'container' } }
  let(:persisted) { [] }
  let(:context) do
    instance_double(Empeira::Application::Context, workspace: Empeira::Workspace.new(path: @directory),
                                                   configuration: { 'mocks' => { 'commands' => commands } })
  end
  let(:execute) { ->(arguments) { runner.run(RbConfig.ruby, arguments: arguments.drop(1)) } }
  let(:persist) { -> { persisted << Marshal.load(Marshal.dump(record)) } }
  let(:reconciler) { described_class.new(context: context, record: record, execute: execute, persist: persist) }

  def invoke(*arguments)
    runner.run(path, arguments: arguments)
  end

  def target_script
    script = File.join(@directory, 'target.sh')
    File.write(script, "#!/bin/sh\nprintf '%s\\000' \"$@\"\nexit 23\n")
    File.chmod(0o755, script)
    script
  end

  it 'creates an executable echo stub with the logical name and all arguments in order' do
    expect(reconciler.reconcile).to be(true)
    expect(File.stat(path).mode & 0o777).to eq(0o755)
    arguments = ['apply', '-f', 'foo.yaml', 'two words', '', '*', '$HOME', 'x;y', '\\n']
    expect(invoke(*arguments)).to have_attributes(stdout: "oc #{arguments.join(' ')}\n", exit_status: 0)
    expect(invoke.stdout).to eq("oc\n")
    expect(File.read(path)).to include('io.empeira.workspace', 'io.empeira.hostname', 'io.empeira.definition')
  end

  it 'leaves file identity, timestamps and inventory untouched on unchanged reconciliation' do
    reconciler.reconcile
    before = File.stat(path)
    writes = persisted.size
    expect(reconciler.reconcile).to be(false)
    expect([File.stat(path).ino, File.stat(path).mtime]).to eq([before.ino, before.mtime])
    expect(persisted.size).to eq(writes)
  end

  it 'forwards arguments to a script without evaluation or word splitting and passes its status through' do
    definition.merge!('mock_to' => target_script, 'exit_code' => 'passthrough')
    reconciler.reconcile
    arguments = ['two words', '', '-n', '*', '$(false)', "line\nbreak", '\\n', '"quotes"']
    expect(invoke(*arguments)).to have_attributes(stdout: "#{arguments.join("\0")}\0", exit_status: 23)
  end

  [0, 7, 255].each do |code|
    it "forces numeric exit #{code} despite a failing target" do
      definition.merge!('mock_to' => target_script, 'exit_code' => code)
      reconciler.reconcile
      expect(invoke('arg')).to have_attributes(stdout: "arg\0", exit_status: code)
    end
  end

  it 'passes through the echo status' do
    definition['exit_code'] = 'passthrough'
    reconciler.reconcile
    expect(invoke('hello')).to have_attributes(stdout: "oc hello\n", exit_status: 0)
  end

  it 'prints the logical name independently of the target basename' do
    commands['logical-name'] = commands.delete('oc')
    reconciler.reconcile
    expect(invoke('arg').stdout).to eq("logical-name arg\n")
  end

  it 'reconciles mock_to and exit_code changes without replacing the node' do
    reconciler.reconcile
    commands['oc'] = definition.merge('mock_to' => target_script, 'exit_code' => 8)
    expect(reconciler.reconcile).to be(true)
    expect(invoke('changed')).to have_attributes(stdout: "changed\0", exit_status: 8)
    expect(record['hostname']).to eq('test-node')
    expect(described_class.valid_inventory?(record['command_mocks'])).to be(true)
  end

  it 'removes the old owned artifact when its target path changes' do
    reconciler.reconcile
    replacement = "#{path}-new"
    commands['oc'] = definition.merge('path' => replacement)
    expect(reconciler.reconcile).to be(true)
    expect(File.exist?(path)).to be(false)
    expect(File.executable?(replacement)).to be(true)
    expect(record['command_mocks'].keys).to eq([replacement])
  end

  it 'removes only an owned artifact when an entry disappears' do
    reconciler.reconcile
    commands.clear
    expect(reconciler.reconcile).to be(true)
    expect(File.exist?(path)).to be(false)
    expect(record['command_mocks']).to eq({})
    expect(reconciler.reconcile).to be(false)
  end

  it 'keeps unrelated commands intact when one is changed or removed' do
    commands['foo'] = definition.merge('path' => "#{path}-foo")
    reconciler.reconcile
    original = File.stat("#{path}-foo")
    commands.delete('oc')
    reconciler.reconcile
    expect(File.stat("#{path}-foo").ino).to eq(original.ino)
  end

  it 'replaces a pre-existing executable at the configured path' do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'foreign')
    expect(reconciler.reconcile).to be(true)
    expect(invoke('arg')).to have_attributes(stdout: "oc arg\n", exit_status: 0)
  end

  it 'reports an unavailable agent Ruby separately from a conflicting target' do
    missing_ruby = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 127, timed_out: false)
    allow(execute).to receive(:call).and_return(missing_ruby)

    expect { reconciler.reconcile }.to raise_error(Empeira::Error, /Cannot run node agent Ruby/)
    expect(execute).to have_received(:call).with([Empeira::Node::Certificates::RUBY, '--version'])
    expect(File.exist?(path)).to be(false)
  end

  it 'restores a replaced mock but refuses to remove an unrelated file' do
    reconciler.reconcile
    File.write(path, 'installed command')
    commands['oc'] = definition.merge('exit_code' => 9)
    expect(reconciler.reconcile).to be(true)
    expect(invoke('arg').exit_status).to eq(9)
    File.write(path, 'installed command again')
    commands.clear
    expect { reconciler.reconcile }.to raise_error(Empeira::Providers::OwnershipError)
    expect(File.read(path)).to eq('installed command again')
  end

  %w[symlink dangling_symlink hardlink].each do |kind|
    it "replaces a #{kind} target without following or changing its other link" do
      foreign = File.join(@directory, 'foreign')
      File.write(foreign, 'foreign')
      FileUtils.mkdir_p(File.dirname(path))
      case kind
      when 'symlink' then File.symlink(foreign, path)
      when 'dangling_symlink' then File.symlink("#{foreign}-missing", path)
      when 'hardlink' then File.link(foreign, path)
      end
      expect(reconciler.reconcile).to be(true)
      expect(File.lstat(path).file?).to be(true)
      expect(invoke.exit_status).to eq(0)
      expect(File.read(foreign)).to eq('foreign')
    end
  end

  %w[directory parent_symlink].each do |kind|
    it "rejects a #{kind} target without changing the foreign resource" do
      foreign = File.join(@directory, 'foreign')
      File.write(foreign, 'foreign')
      FileUtils.mkdir_p(File.dirname(path))
      case kind
      when 'directory' then Dir.mkdir(path)
      when 'parent_symlink'
        Dir.rmdir(File.dirname(path))
        File.symlink(@directory, File.dirname(path))
      end
      expect { reconciler.reconcile }.to raise_error(Empeira::Providers::OwnershipError)
      expect(File.read(foreign)).to eq('foreign')
    end
  end

  it 'replaces a mock with another node ownership marker at the configured path' do
    reconciler.reconcile
    record['hostname'] = 'another-node'
    expect(reconciler.reconcile).to be(true)
    expect(File.read(path)).to include('another-node')
  end

  it 'replaces a mock with another workspace ownership marker at the configured path' do
    reconciler.reconcile
    previous = File.read(path)
    other = File.join(@directory, 'other')
    initialize_project(other)
    allow(context).to receive(:workspace).and_return(Empeira::Workspace.new(path: other))
    expect(reconciler.reconcile).to be(true)
    expect(File.read(path)).not_to eq(previous)
  end

  it 'restores a missing managed artifact and repairs executable mode' do
    reconciler.reconcile
    File.unlink(path)
    expect(reconciler.reconcile).to be(true)
    File.chmod(0o644, path)
    expect(reconciler.reconcile).to be(true)
    expect(File.stat(path).mode & 0o777).to eq(0o755)
  end

  it 'records ownership intent before guest writes and recovers a lost response' do
    lose_response = true
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      expect(persisted.last.dig('command_mocks', path, 'definition')).to eq(definition)
      result = method.call(arguments)
      next result unless lose_response

      lose_response = false
      raise Empeira::Error, 'connection lost'
    end
    expect { reconciler.reconcile }.to raise_error(Empeira::Error, /connection lost/)
    expect(reconciler.reconcile).to be(false)
    commands.clear
    expect(reconciler.reconcile).to be(true)
  end

  it 'recovers an interrupted replacement through the same persisted node inventory' do
    reconciler.reconcile
    commands['oc'] = definition.merge('exit_code' => 6)
    lose_response = true
    allow(execute).to receive(:call).and_wrap_original do |method, arguments|
      result = method.call(arguments)
      next result unless lose_response

      lose_response = false
      raise Empeira::Error, 'connection lost'
    end
    expect { reconciler.reconcile }.to raise_error(Empeira::Error)
    expect(record.dig('command_mocks', path)).to have_key('previous')
    expect(reconciler.reconcile).to be(false)
    expect(invoke.exit_status).to eq(6)
    expect(record.dig('command_mocks', path)).not_to have_key('previous')
  end

  it 'does nothing without configured or recorded mocks' do
    commands.clear
    expect(execute).not_to receive(:call)
    expect(reconciler.reconcile).to be(false)
    expect(record).not_to have_key('command_mocks')
    expect(persisted).to be_empty
  end

  it 'rejects malformed or tampered resource state' do
    reconciler.reconcile
    entries = record.fetch('command_mocks')
    entries[path]['definition'] = definition.merge('path' => '/etc/hosts')
    expect(described_class.valid_inventory?(entries)).to be(false)
    expect(described_class.valid_inventory?(nil)).to be(false)
  end
end

RSpec.describe Empeira::Node::Service do
  let(:configuration) { { 'mocks' => { 'commands' => {} } } }
  let(:context) { instance_double(Empeira::Application::Context, configuration: configuration) }
  let(:providers) { instance_double(Empeira::Providers::Registry) }
  let(:service) { described_class.new(context: context, runner: Empeira::Execution::Runner.new, providers: providers) }

  it 'does not construct providers when there are no nodes to reconcile' do
    expect(providers).not_to receive(:build)
    expect(service.reconcile(state: { 'nodes' => {} })).to be(false)
  end

  it 'routes cleanup to both recorded providers without short-circuiting after a change' do
    state = { 'nodes' => { 'one' => { 'provider' => 'container', 'command_mocks' => { 'owned' => {} } },
                           'two' => { 'provider' => 'vm', 'command_mocks' => { 'owned' => {} } } } }
    container = instance_double(Empeira::Node::Container)
    vm = instance_double(Empeira::Node::VM)
    expect(providers).to receive(:build).with('container', anything).and_return(container)
    expect(providers).to receive(:build).with('vm', anything).and_return(vm)
    expect(container).to receive(:reconcile_all).with(state: state).and_return(true)
    expect(vm).to receive(:reconcile_all).with(state: state).and_return(false)
    expect(service.reconcile(state: state)).to be(true)
  end
end
