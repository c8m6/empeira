# frozen_string_literal: true

require_relative 'support/service_runtime'

RSpec.describe 'Update plane' do
  let(:runtime) { ServiceRuntime.new }
  let(:registry) { instance_double(Empeira::Providers::Registry) }
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
  let(:app) do
    Empeira::Application.new(project_path: @directory, locations: locations, factories: { runtimes: registry })
  end
  let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
  let(:root) { Empeira::Modules::Storage.new(context: app.context).root }

  before do
    allow(runtime).to receive(:with_image_updates).and_yield
    File.write(File.join(@directory, 'Puppetfile'), "mod 'fixture-sample', '1.0.0'")
    allow(registry).to receive(:build).and_return(runtime)
    allow(runtime).to receive(:check_available!).and_return(true)
    @installer = instance_double(Empeira::Modules::Installer)
    allow(Empeira::Modules::Installer).to receive(:new).and_return(@installer)
    allow(@installer).to receive(:synchronize) do |_request, target, **|
      target.join('sample').mkpath
      target.join('sample/value').write('complete')
      ['sample']
    end
    expect(Empeira::ControlPlane::Controller).not_to receive(:new)
    expect(runtime).not_to receive(:create_network)
    expect(runtime).not_to receive(:create_service)
    expect(runtime).not_to receive(:start_service)
  end

  it 'installs directly into modules.path without deployment metadata or runtime state' do
    app.updates.update('modules')
    expect(root.join('sample/value').read).to eq('complete')
    expect(root.children.map { |path| path.basename.to_s }).to eq(['sample'])
    expect(root.to_s).to eq("#{File.realpath(@directory)}/modules")
    expect(store.load).to be_nil
  end

  it 'updates the same directory and leaves runtime inventory unchanged' do
    app.updates.update('modules')
    inode = root.join('sample').stat.ino
    inventory = store.directory.join('infrastructure.json')
    inventory.write('untouched runtime inventory')
    app.updates.update('modules')
    expect(inventory.read).to eq('untouched runtime inventory')
    expect(root.join('sample').stat.ino).to eq(inode)
  end

  it 'allows partial updates but requires a new sync after failure' do
    app.updates.update('modules')
    allow(@installer).to receive(:synchronize) do |_request, target, **|
      target.join('sample/value').write('partial change')
      raise Empeira::Error, 'synthetic download failure'
    end
    expect { app.updates.update('modules') }.to raise_error(Empeira::Error, /download failure/)
    expect(root.join('sample/value').read).to eq('partial change')
    updater = Empeira::Updates::Modules.new(context: app.context, runtime: runtime, runner: app.runner)
    expect { updater.synchronize }.to raise_error(Empeira::Error, /download failure/)
    expect(store.load).to be_nil
  end

  it 'ignores workspace proxy policy and avoids a helper on up with unchanged available modules' do
    config = { 'proxy' => { 'enabled' => true, 'global' => ['denied.example'] } }
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
    app.updates.update('modules')
    expect(@installer).not_to receive(:synchronize)
    Empeira::Modules::Request.new(context: app.context).verify_available!
    expect(store.load).to be_nil
  end

  it 'allows existing modules after Puppetfile changes without implicit synchronization' do
    app.updates.update('modules')
    File.open(File.join(@directory, 'Puppetfile'), 'a') { |file| file.puts "\n# changed definition" }
    expect(@installer).not_to receive(:synchronize)
    Empeira::Modules::Request.new(context: app.context).verify_available!
  end

  it 'uses a custom module directory directly' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('modules' => { 'path' => '.cache/custom-modules' }))
    app.updates.update('modules')
    expect(root.join('sample/value').read).to eq('complete')
    expect(root.to_s).to eq("#{File.realpath(@directory)}/.cache/custom-modules")
    expect(root.join('.empeira')).not_to exist
  end

  it 'checks the version requirement before taking the workspace lock or contacting a runtime' do
    File.write(File.join(@directory, '.empeira.yaml'), 'requirements: {empeira: ">= 999.0"}')
    expect(registry).not_to receive(:build)
    expect { app.updates.update('modules') }.to raise_error(Empeira::Error, /version requirement/)
    expect(store.directory).not_to exist
  end

  it 'fails update all before any target mutation while self-update is unavailable' do
    expect(@installer).not_to receive(:synchronize)
    expect(registry).not_to receive(:build)
    expect { app.updates.update('all') }.to raise_error(Empeira::UnavailableFeature, /self-update/)
    expect(store.directory).not_to exist
  end
  it 'refreshes configured container images through runtime registry operations with no infrastructure' do
    allow(runtime).to receive(:architecture).and_return('amd64')
    images = []
    allow(runtime).to receive(:refresh_image) { |image, **options| images << [image, options] }
    app.updates.update('images')
    expected = %w[server dns].map do |key|
      Empeira::Images::Configuration.reference(app.context.configuration.dig('images', key))
    end
    expect(images.map(&:first)).to include(*expected)
    expect(images.map(&:first).grep(/empeira-node/).size).to eq(1)
    expect(images.map(&:first).grep(/empeira-r10k/).size).to eq(1)
    expect(store.load).to be_nil
  end

  it 'propagates registry failures without invoking modules or starting infrastructure' do
    allow(runtime).to receive(:architecture).and_return('amd64')
    allow(runtime).to receive(:refresh_image).and_raise(Empeira::Providers::ExecutionError, 'registry denied')
    expect(@installer).not_to receive(:synchronize)
    expect { app.updates.update('images') }.to raise_error(Empeira::Error, /registry denied/)
    expect(store.load).to be_nil
  end
end
