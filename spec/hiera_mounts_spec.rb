# frozen_string_literal: true

RSpec.describe Empeira::Configuration::HieraMounts do
  let(:module_mount) { { 'source' => 'external', 'type' => 'module', 'name' => 'hieradata_example' } }
  let(:environment_mount) { { 'source' => 'external', 'type' => 'environment', 'target' => 'data/external' } }

  def resolve(entries, environment: 'testing')
    described_class.new(config: { 'mounts' => entries }, project: @directory, environment: environment)
  end

  before { FileUtils.mkdir_p(File.join(@directory, 'external')) }

  it 'supports empty mounts and canonical relative/absolute sources at Puppet destinations' do
    expect(resolve([]).mounts).to be_empty
    result = resolve([module_mount, environment_mount.merge('source' => File.join(@directory, 'external'))])
    expect(result.mounts).to include(
      "type=bind,src=#{File.realpath(@directory)}/external," \
      'dst=/etc/puppetlabs/code/environments/testing/modules/hieradata_example,readonly',
      "type=bind,src=#{File.realpath(@directory)}/external," \
      'dst=/etc/puppetlabs/code/environments/testing/data/external,readonly'
    )
    expect(result.entries.map { |entry| entry['required'] }).to eq([false, false])
  end

  it 'skips missing, dangling and inaccessible optional repositories visibly but rejects required ones' do
    File.symlink('absent', File.join(@directory, 'dangling'))
    %w[absent dangling].each do |source|
      mount = module_mount.merge('source' => source)
      result = resolve([mount])
      expect(result.mounts).to be_empty
      expect(result.warnings.join).to include(source, 'skipped', 'missing source')
      expect do
        resolve([mount.merge('required' => true)])
      end.to raise_error(Empeira::ConfigurationError, /hiera.mounts.0.source/)
    end
    allow_any_instance_of(Pathname).to receive(:readable?).and_return(false)
    expect(resolve([module_mount]).warnings.join).to include('inaccessible source')
    expect do
      resolve([module_mount.merge('required' => true)])
    end.to raise_error(Empeira::ConfigurationError,
                       /required but unavailable/)
  end

  it 'rejects existing non-directories, unsafe sources and looping symlinks even when optional' do
    File.write(File.join(@directory, 'file'), 'data')
    File.symlink('loop', File.join(@directory, 'loop'))
    ['file', 'loop', 'bad,path', "bad\npath"].each do |source|
      expect do
        resolve([module_mount.merge('source' => source)])
      end.to raise_error(Empeira::ConfigurationError,
                         /hiera.mounts.0.source/)
    end
  end

  it 'rejects malformed definitions and traversing targets before checking absent sources' do
    [module_mount.except('name'), environment_mount.except('target'), module_mount.merge('type' => 'bind'),
     module_mount.merge('required' => 'false'), module_mount.merge('extra' => true)].each do |mount|
      expect { resolve([mount]) }.to raise_error(Empeira::ConfigurationError, /hiera.mounts.0/)
    end
    ['/etc/data', '../data', 'data/../etc', './data', '.', '', 'data//x', 'data,x'].each do |target|
      expect { resolve([environment_mount.merge('source' => 'absent', 'target' => target)]) }
        .to raise_error(Empeira::ConfigurationError, /target/)
    end
  end

  it 'rejects duplicate and overlapping targets across both types, including unavailable sources' do
    [[module_mount, module_mount], [environment_mount, environment_mount],
     [module_mount, environment_mount.merge('target' => 'modules/hieradata_example/data')]].each do |mounts|
      expect { resolve(mounts) }.to raise_error(Empeira::ConfigurationError, /overlaps/)
    end
  end

  it 'rejects destinations whose existing symlink escapes the environment' do
    Dir.mktmpdir('external-target-') do |outside|
      File.symlink(outside, File.join(@directory, 'data'))
      expect { resolve([environment_mount]) }.to raise_error(Empeira::ConfigurationError, /inside the environment/)
    end
  end

  it 'accepts the default modulepath and explicit modules, but explains explicit exclusion' do
    path = File.join(@directory, 'environment.conf')
    expect(resolve([module_mount]).mounts.size).to eq(1)
    File.write(path, "modulepath = site:./modules:$basemodulepath\n")
    expect(resolve([module_mount]).mounts.size).to eq(1)
    File.write(path, "modulepath = site:$basemodulepath\n")
    expect { resolve([module_mount]) }.to raise_error(Empeira::ConfigurationError, /environment.conf modulepath/)
    expect(resolve([environment_mount]).mounts.size).to eq(1)
  end

  it 'fingerprints configuration and availability only, keeping file edits live' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('hiera' => { 'mounts' => [module_mount] }))
    app = Empeira::Application.new(project_path: @directory)
    plan = -> { Empeira::ControlPlane::Plan.new(context: app.context).fingerprints }
    original = plan.call
    File.write(File.join(@directory, 'external/data.yaml'), 'value: changed')
    expect(plan.call).to eq(original)
    FileUtils.rm_rf(File.join(@directory, 'external'))
    changed = plan.call
    expect(changed.except('server')).to eq(original.except('server'))
    expect(changed['server']).not_to eq(original['server'])
  end

  it 'reconciles only the server when source, type, target, name or required metadata changes' do
    FileUtils.mkdir_p(File.join(@directory, 'another'))
    fingerprints = lambda do |mount|
      File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('hiera' => { 'mounts' => [mount] }))
      app = Empeira::Application.new(project_path: @directory)
      Empeira::ControlPlane::Plan.new(context: app.context).fingerprints
    end
    original = fingerprints.call(module_mount)
    [module_mount.merge('required' => true), module_mount.merge('source' => 'another'),
     module_mount.merge('name' => 'another_name'), environment_mount,
     environment_mount.merge('target' => 'different/data')].each do |mount|
      changed = fingerprints.call(mount)
      expect(changed.except('server')).to eq(original.except('server'))
      expect(changed['server']).not_to eq(original['server'])
    end
  end
end

RSpec.describe Empeira::ControlPlane::Environment do
  let(:app) do
    Empeira::Application.new(project_path: @directory,
                             locations: Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                                         environment: {}))
  end

  it 'creates mount placeholders in managed state without modifying the live control repository' do
    File.write(File.join(@directory, 'environment.conf'), "modulepath = modules:$basemodulepath\n")
    source = Pathname(@directory).join('external')
    source.mkdir
    hiera = Empeira::Configuration::HieraMounts.new(
      config: { 'mounts' => [{ 'source' => source.to_s, 'type' => 'module', 'name' => 'hieradata' }] },
      project: @directory, environment: 'production'
    )
    environment = described_class.new(context: app.context, hiera: hiera)
    environment.prepare
    directory = app.context.locations.workspace(app.context.workspace).join('environments').children.first
    expect(directory.join('modules/hieradata')).to be_directory
    expect(directory.join('environment.conf').readlink.to_s).to eq('/empeira-control/environment.conf')
    expect(Pathname(@directory).join('modules')).not_to exist
    environment.cleanup
    expect(directory).not_to exist
    expect(source).to be_directory
  end
end
