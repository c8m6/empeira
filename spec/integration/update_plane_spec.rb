# frozen_string_literal: true

require_relative '../support/module_source'

RSpec.describe 'Standalone update helpers', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:registry) { instance_double(Empeira::Providers::Registry) }
      let(:app) do
        Empeira::Application.new(project_path: @directory, locations: locations, factories: { runtimes: registry })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
      let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }
      let(:root) { Empeira::Modules::Storage.new(context: app.context).root }

      before do
        skip 'Set EMPEIRA_INTEGRATION=update-plane for real helpers and public Forge access' unless
          ENV['EMPEIRA_INTEGRATION'] == 'update-plane'

        config = { 'runtime' => { 'container_engine' => engine }, 'proxy' => { 'global' => ['unused.invalid'] },
                   'modules' => { 'path' => engine == 'docker' ? '.cache/modules' : 'modules' } }
        File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(config))
        allow(registry).to receive(:build).and_return(runtime)
        runtime.check_available!
        @helpers = []
        @helper_identity = nil
        allow(runtime).to receive(:with_update_helper).and_wrap_original do |method, **options, &block|
          method.call(**options) do |resource|
            @helper_identity = Empeira::Services::Definition.new(
              key: resource.fetch('labels').fetch('io.empeira.purpose'), workspace: app.context.workspace
            )
            observed = runtime.inspect_service(@helper_identity, expected_id: resource.fetch('id'))
            @helpers << observed
            expect(observed.fetch('networks').keys).to eq([engine == 'docker' ? 'bridge' : 'podman'])
            expect(observed.fetch('name')).not_to include('.empeira.internal')
            expect(observed.fetch('mounts').find do |mount|
              mount['Destination'] == '/work/Puppetfile'
            end['RW']).to be(false)
            expect(store.load).to be_nil
            block.call(resource)
          end
        end
        expect(runtime).not_to receive(:create_network)
        expect(runtime).not_to receive(:create_service)
        expect(Empeira::ControlPlane::Controller).not_to receive(:new)
      end

      after { @source&.close }

      it 'refreshes a registry image without creating services or workspace state' do
        # Exercise the real image-update command with a small catalog; unit tests cover the full selection.
        image = Empeira::Images::Configuration.reference(app.context.configuration.dig('images', 'dns'))
        updater = Empeira::Updates::Images.new(context: app.context, runtime: runtime)
        allow(Empeira::Updates::Images).to receive(:new).and_return(updater)
        allow(updater).to receive_messages(service_images: [{ image: image, label: 'CoreDNS' }], utility_images: [],
                                           node_images: [])
        app.updates.update('images')
        expect(runtime.image_id(image)).not_to be_empty
        expect(store.load).to be_nil
        expect(@helpers).to be_empty
      end

      it 'refreshes a reviewed build through normal registry access without starting services' do
        base = Empeira::Images::Configuration.reference(app.context.configuration.dig('images', 'dns'))
        recipe = "ARG EMPEIRA_BASE_TEST=#{base}\nFROM ${EMPEIRA_BASE_TEST}\nLABEL io.empeira.test=update-plane\n"
        image = "localhost/empeira-update-test:#{SecureRandom.hex(16)}"
        runtime.refresh_image(image, recipe: recipe)
        built = true
        runtime.ensure_image(image, recipe: recipe)
        first = runtime.image_id(image)
        runtime.refresh_image(image, recipe: recipe)
        expect(runtime.image_id(image)).to eq(first)
        expect(store.load).to be_nil
      ensure
        runtime.update_command(['image', 'rm', image], operation: 'test image cleanup') if built
      end

      it 'builds a new reviewed artifact when its configured base image changes' do
        bases = [Empeira::Images::Configuration.reference(app.context.configuration.dig('images', 'dns')),
                 Empeira::Images::Configuration.reference(app.context.configuration.dig('images', 'server'))]
        images = []
        identities = bases.map do |base|
          image = "localhost/empeira-base-change-test:#{SecureRandom.hex(16)}"
          images << image
          runtime.refresh_image(image,
                                recipe: "ARG EMPEIRA_BASE_TEST=#{base}\nFROM ${EMPEIRA_BASE_TEST}\n" \
                                        "LABEL io.empeira.test=changed-base\n")
          runtime.image_id(image)
        end
        expect(identities.uniq.size).to eq(2)
        expect(store.load).to be_nil
      ensure
        images&.each do |image|
          runtime.update_command(['image', 'rm', image], operation: 'test changed-base cleanup')
        end
      end

      it 'uses public Forge and host Git with no runtime infrastructure, retaining complete host artifacts' do
        @source = ModuleSource.new(@directory).start
        File.write(File.join(@directory, 'Puppetfile'),
                   "mod 'puppetlabs-stdlib', '9.6.0'\n" \
                   "mod 'profile', git: '#{@source.url}/fixture.git', commit: '#{@source.commit}'\n")
        app.updates.update('modules')
        expect(root.children.map { |path| path.basename.to_s }.sort).to eq(%w[profile stdlib])
        inode = root.join('profile/.git').stat.ino
        expect(root.join('profile/value.txt').read).to eq('synthetic Git module')
        metadata = JSON.parse(root.join('stdlib/metadata.json').read)
        expect(metadata.fetch('license')).to eq('Apache-2.0')
        expect(runtime.inspect_service(@helper_identity)).to be_nil
        expect(store.load).to be_nil
        app.updates.update('modules')
        expect(root.join('profile/.git').stat.ino).to eq(inode)
        expect(root.join('.empeira')).not_to exist
        @source.close
        @source = nil
        Empeira::Modules::Request.new(context: app.context).verify_available!
        expect(@helpers.size).to eq(2)
        # Invalid versions report the failing module and leave no helper behind.
        File.write(File.join(@directory, 'Puppetfile'), "mod 'puppetlabs-stdlib', '0.0.0-nonexistent'\n")
        expect { app.updates.update('modules') }.to raise_error(Empeira::Error, /Module.*stdlib/m)
        expect(runtime.inspect_service(@helper_identity)).to be_nil
        expect(store.load).to be_nil
        # Existing modules remain plausible even when a later update fails.
        Empeira::Modules::Request.new(context: app.context).verify_available!
        expect(runtime.inspect_service(@helper_identity)).to be_nil
        expect(store.load).to be_nil
      end
    end
  end
end
