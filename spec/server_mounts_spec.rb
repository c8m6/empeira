# frozen_string_literal: true

require 'socket'

RSpec.describe Empeira::Configuration::ServerMounts do
  let(:entry) { { 'source' => 'artifacts', 'target' => '/srv/puppet-artifacts' } }

  before { FileUtils.mkdir_p(File.join(@directory, 'artifacts')) }

  def resolve(entries)
    described_class.new(entries: entries, project: File.realpath(@directory)).entries
  end

  def plan(entries = [], extra = {})
    config = Empeira::Configuration::Merge.call({ 'server' => { 'mounts' => entries } }, extra)
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    Empeira::ControlPlane::Plan.new(context: Empeira::Application.new(project_path: @directory).context)
  end

  it 'defaults to no mounts and resolves files, directories and canonical symlinks with readonly by default' do
    expect(plan.config.dig('server', 'mounts')).to eq([])
    File.write(File.join(@directory, 'value.txt'), 'fixture')
    File.symlink('artifacts', File.join(@directory, 'alias'))
    %w[artifacts alias value.txt].each do |source|
      expected = File.realpath(File.join(@directory, source))
      [source, File.join(@directory, source)].each do |value|
        expect(resolve([entry.merge('source' => value)]).first)
          .to eq(entry.merge('source' => expected, 'readonly' => true))
      end
    end
  end

  it 'resolves relative sources from the canonical Git root even when invoked below it or through a symlink' do
    project = File.join(@directory, 'control')
    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'nested'))
    File.symlink(project, File.join(@directory, 'project-link'))
    File.write(File.join(project, '.empeira.yaml'),
               YAML.dump('server' => { 'mounts' => [entry.merge('source' => '../artifacts')] }))
    context = Empeira::Application.new(project_path: File.join(@directory, 'project-link/nested')).context
    expect(Empeira::ControlPlane::Plan.new(context: context).project_server_mounts)
      .to eq(["type=bind,src=#{File.realpath(@directory)}/artifacts,dst=/srv/puppet-artifacts,readonly"])
  end

  it 'normalizes targets and only permits an explicit boolean false to make a writable mount' do
    value = plan([entry.merge('target' => '/srv//./data/', 'readonly' => false)]).project_server_mounts
    expect(value).to eq(["type=bind,src=#{File.realpath(@directory)}/artifacts,dst=/srv/data"])
    [nil, 'false', 0].each do |readonly|
      expect { resolve([entry.merge('readonly' => readonly)]) }
        .to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].readonly/)
    end
  end

  it 'rejects invalid mappings, unknown options and missing paths with full configuration paths' do
    [nil, {}, 'type=bind'].each do |entries|
      expect { resolve(entries) }.to raise_error(Empeira::ConfigurationError, /server.mounts/)
    end
    [nil, 'raw', entry.merge('options' => 'rw,z'), entry.except('source'), entry.except('target')].each do |value|
      expect { resolve([value]) }.to raise_error(Empeira::ConfigurationError, /server.mounts\[0\]/)
    end
  end

  it 'rejects unsafe target paths, raw runtime options and device injection' do
    ['', 'relative', '/', '/./', '/etc/../srv', '/srv/..', "/srv/a\n", "/srv/a\0", "/srv/a\u0085",
     '/srv/a,readonly=false', '/dev', '/dev/null', '/proc', '/sys/kernel'].each do |target|
      expect { resolve([entry.merge('target' => target)]) }
        .to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].target/)
    end
  end

  it 'rejects missing sources, broken symlinks, special files and unsafe resolved paths' do
    File.symlink('missing', File.join(@directory, 'broken'))
    FileUtils.mkdir_p(File.join(@directory, 'unsafe,readonly=false'))
    File.symlink('unsafe,readonly=false', File.join(@directory, 'unsafe-alias'))
    ['', 'missing', 'broken', 'unsafe-alias', '/dev', '/dev/null', '/', "artifacts\n", "artifacts\0",
     "artifacts\u007f", 'artifacts,readonly=false'].each do |source|
      expect { resolve([entry.merge('source' => source)]) }
        .to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].source/)
    end
  end

  it 'rejects sockets directly and through a containing data directory' do
    socket = UNIXServer.new(File.join(@directory, 'artifacts/runtime.sock'))
    %w[artifacts/runtime.sock artifacts].each do |source|
      expect { resolve([entry.merge('source' => source)]) }
        .to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].source/)
    end
  ensure
    socket&.close
  end

  it 'rejects duplicate and overlapping normalized user targets in either order, but allows siblings' do
    ['/srv/puppet-artifacts', '/srv/./puppet-artifacts/', '/srv', '/srv/puppet-artifacts/child'].each do |target|
      entries = [entry, entry.merge('target' => target)]
      [entries, entries.reverse].each do |values|
        expect { resolve(values) }.to raise_error(Empeira::ConfigurationError, /server.mounts\[1\].target overlaps/)
      end
    end
    expect(resolve([entry, entry.merge('target' => '/srv/puppet-artifacts-other')]).size).to eq(2)
  end

  it 'protects every managed mount including its ancestors and descendants' do
    File.write(File.join(@directory, 'key.pem'), 'synthetic-key')
    File.write(File.join(@directory, 'Puppetfile'), '')
    extra = {
      'hiera' => { 'mounts' => [{ 'source' => 'artifacts', 'type' => 'environment', 'target' => 'data' }] },
      'eyaml' => { 'enabled' => true, 'private_key' => 'key.pem', 'public_key' => 'key.pem' }
    }
    original = plan([], extra).definitions.fetch('server').options.fetch('mounts')
    original.each do |mount|
      target = mount.split(',').find { |field| field.start_with?('dst=') }.delete_prefix('dst=')
      [target, "#{target}/child", File.dirname(target)].reject { |path| path == '/' }.each do |candidate|
        expect { plan([entry.merge('target' => candidate)], extra).definitions }
          .to raise_error(Empeira::ConfigurationError, /server.mounts\[0\].target overlaps an Empeira-managed/)
      end
    end
    expect(plan([entry], extra).definitions.fetch('server').options.fetch('mounts'))
      .to eq(original + ["type=bind,src=#{File.realpath(@directory)}/artifacts,dst=/srv/puppet-artifacts,readonly"])
  end

  it 'adds mounts only to the server and changes only its fingerprint for source, target or readonly changes' do
    extra = { 'containers' => { 'additional' => [{ 'name' => 'viewer', 'image' => { 'repository' => 'example/viewer',
                                                                                    'tag' => '1' } }] },
              'proxy' => { 'enabled' => true } }
    baseline = plan([], extra)
    baseline.browser_enabled = true
    original = baseline.fingerprints
    FileUtils.mkdir_p(File.join(@directory, 'second'))
    [entry, entry.merge('source' => 'second'), entry.merge('target' => '/srv/other'),
     entry.merge('readonly' => false)].each do |mount|
      current = plan([mount], extra)
      current.browser_enabled = true
      expect(current.fingerprints.except('server')).to eq(original.except('server'))
      expect(current.fingerprints.fetch('server')).not_to eq(original.fetch('server'))
      original = current.fingerprints
    end
  end

  it 'does not hash live source contents or directory entries' do
    original = plan([entry]).fingerprints
    File.write(File.join(@directory, 'artifacts/value.txt'), 'first')
    expect(plan([entry]).fingerprints).to eq(original)
    File.write(File.join(@directory, 'artifacts/value.txt'), 'second')
    expect(plan([entry]).fingerprints).to eq(original)
  end

  %w[docker podman].each do |engine|
    it "passes structured bind mounts as individual arguments to #{engine}" do
      value = plan([entry, entry.merge('target' => '/srv/writable', 'readonly' => false)])
      definition = value.definitions.fetch('server')
      runner = instance_double(Empeira::Execution::Runner)
      runtime = Empeira::Runtime.registry.build(engine, context: value.context, runner: runner)
      success = Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      expect(runner).to receive(:run).with(engine, arguments: satisfy { |arguments|
        mounts = arguments.each_cons(2).filter_map { |flag, mount| mount if flag == '--mount' }
        mounts == definition.options.fetch('mounts') &&
          mounts.last(2) == ["type=bind,src=#{File.realpath(@directory)}/artifacts,dst=/srv/puppet-artifacts,readonly",
                             "type=bind,src=#{File.realpath(@directory)}/artifacts,dst=/srv/writable"]
      }, timeout: anything).and_return(success)
      allow(runtime).to receive(:inspect_service).with(definition).and_return(nil)
      runtime.create_service(definition)
    end
  end
end
