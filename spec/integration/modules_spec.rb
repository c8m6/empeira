# frozen_string_literal: true

require_relative '../support/module_source'

RSpec.describe 'Puppetfile runtime synchronization', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { File.join(@directory, 'control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:events) { [] }
      let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }
      def app
        Empeira::Application.new(project_path: project, locations: locations, progress: progress)
      end

      def up
        progress.run('Preparing modules...') { app.infrastructure.up }
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
      let(:store) { Empeira::Infrastructure::Store.new(context: app.context) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=modules for real Docker/Podman module synchronization' unless
          ENV['EMPEIRA_INTEGRATION'] == 'modules'

        initialize_project(project)
        FileUtils.mkdir_p(File.join(project, 'local-data'))
        File.write(File.join(project, 'local-data/value.txt'), 'local Hiera wins')
        @config = {
          'runtime' => { 'container_engine' => engine }, 'puppetdb' => { 'enabled' => false },
          'hiera' => { 'mounts' => [{ 'source' => './local-data', 'type' => 'module', 'name' => 'hieradata' }] }
        }
        @config['modules'] = { 'path' => '.cache/puppet-modules' } if engine == 'docker'
        write_config
        File.write(File.join(project, 'Puppetfile'), '')
        runtime.check_available!
      end

      after do
        @source&.close
        app.infrastructure.destroy if ENV['EMPEIRA_INTEGRATION'] == 'modules' && File.directory?(project)
      end

      def write_config
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(@config))
      end

      def service(key)
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        runtime.inspect_service(plan.definitions.fetch(key))
      end

      def populate_source
        @source = ModuleSource.new(@directory).start
        "mod 'profile', git: '#{@source.url}/fixture.git', commit: '#{@source.commit}'\n" \
          "mod 'owner-hieradata', git: 'ssh://unreachable.invalid/hieradata'\n"
      end

      it 'updates live modules in place, preserves local overrides and retains modules across destroy' do
        content = populate_source
        File.write(File.join(project, 'Puppetfile'), content)
        expect { up }.to raise_error(Empeira::Error, /update modules/)
        progress.run('Updating modules...') { app.updates.update('modules') }
        prepare_images
        expect(runtime).not_to receive(:refresh_image)
        up
        target = Empeira::Modules::Storage.new(context: app.context).root
        expect(target.join('profile/value.txt').read).to eq('synthetic Git module')
        expect(target.join('.empeira')).not_to exist
        expect(events.map(&:message)).to include('profile (1/1)', 'hieradata (local override)')
        server = service('server')
        root = '/etc/puppetlabs/code/environments/production/modules'
        expect(runtime.service_exec(server, ['cat', "#{root}/hieradata/value.txt"]).stdout).to eq('local Hiera wins')
        expect(runtime.service_exec(server, ['touch', "#{root}/profile/forbidden"])).not_to be_success
        up
        expect(service('server').fetch('id')).to eq(server.fetch('id'))
        previous = store.load
        app.updates.update('modules')
        expect(store.load).to eq(previous)
        expect(target.join('profile/value.txt').read).to eq('synthetic Git module')
        # A direct host edit is visible immediately, with no runtime activation.
        target.join('profile/value.txt').write('live module change')
        expect(runtime.service_exec(server, ['cat', "#{root}/profile/value.txt"]).stdout).to eq('live module change')
        app.updates.update('modules')
        expect(runtime.service_exec(server, ['cat', "#{root}/profile/value.txt"]).stdout).to eq('synthetic Git module')
        expect(service('server').fetch('id')).to eq(server.fetch('id'))
        verify_destroy_reuse(target)
      end

      def prepare_images
        plan = Empeira::ControlPlane::Plan.new(context: app.context)
        plan.definitions.each_value do |definition|
          runtime.ensure_image(definition.options.fetch('image'), recipe: definition.options['recipe'])
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Verify real retained content and an offline restart together.
      def verify_destroy_reuse(target)
        app.infrastructure.destroy
        expect(target.join('profile/value.txt')).to be_file
        expect(store.load).to be_nil
        @source.close
        @source = nil
        expect(runtime).not_to receive(:with_update_helper)
        up
        root = '/etc/puppetlabs/code/environments/production/modules'
        expect(runtime.service_exec(service('server'), ['cat', "#{root}/profile/value.txt"]).stdout)
          .to eq('synthetic Git module')
      end
    end
  end
end
