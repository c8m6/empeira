# frozen_string_literal: true

RSpec.describe 'Real server bind mounts', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:selected_engine) { engine }
      let(:project) { File.join(@directory, 'control') }
      let(:source) { File.join(project, 'fixtures/server-files') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: application.context, runner: application.runner) }

      def application
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => selected_engine } })
      end

      def configure(target:, readonly: true)
        mount = { 'source' => 'fixtures/server-files', 'target' => target, 'readonly' => readonly }
        config = { 'puppetdb' => { 'enabled' => false }, 'server' => { 'mounts' => [mount] } }
        File.write(File.join(project, '.empeira.yaml'), YAML.dump(config))
      end

      def service(key)
        runtime.inspect_service(Empeira::Services::Definition.new(key: key, workspace: application.context.workspace))
      end

      before do
        skip 'Set EMPEIRA_INTEGRATION=mounts for actual bind mount tests' unless ENV['EMPEIRA_INTEGRATION'] == 'mounts'

        initialize_project(project)
        FileUtils.mkdir_p(source)
        FileUtils.chmod(0o755, @directory)
        FileUtils.chmod(0o777, source)
        File.write(File.join(source, 'value.txt'), 'first')
        configure(target: '/srv/empeira-test')
        runtime.check_available!
        @available = true
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after { application.infrastructure.destroy if @available }

      it 'enforces readonly, exposes live edits, and selectively reconciles writable and target changes' do
        application.infrastructure.up
        server = service('server')
        dns = service('dns').fetch('id')
        expect(runtime.service_exec(server, %w[cat /srv/empeira-test/value.txt]).stdout).to eq('first')
        expect(runtime.service_exec(server, %w[touch /srv/empeira-test/denied])).not_to be_success
        File.write(File.join(source, 'value.txt'), 'second')
        expect(runtime.service_exec(server, %w[cat /srv/empeira-test/value.txt]).stdout).to eq('second')
        application.infrastructure.up
        expect(service('server').fetch('id')).to eq(server.fetch('id'))

        configure(target: '/srv/empeira-test', readonly: false)
        application.infrastructure.up
        writable = service('server')
        expect(writable.fetch('id')).not_to eq(server.fetch('id'))
        expect(runtime.service_exec(writable, %w[touch /srv/empeira-test/allowed])).to be_success
        expect(File).to exist(File.join(source, 'allowed'))

        configure(target: '/srv/empeira-moved')
        application.infrastructure.up
        moved = service('server')
        expect(moved.fetch('id')).not_to eq(writable.fetch('id'))
        expect(runtime.service_exec(moved, %w[cat /srv/empeira-moved/value.txt]).stdout).to eq('second')
        expect(runtime.service_exec(moved, %w[test -e /srv/empeira-test/value.txt])).not_to be_success
        expect(service('dns').fetch('id')).to eq(dns)
      end
    end
  end
end
