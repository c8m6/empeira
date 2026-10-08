# frozen_string_literal: true

RSpec.describe 'Real container runtime integration', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:apps) do
        %w[first second].map do |name|
          project = File.join(@directory, name)
          initialize_project(project)
          Empeira::Application.new(project_path: project, locations: locations,
                                   overrides: { 'runtime' => { 'container_engine' => engine } })
        end
      end

      before do
        unless ENV['EMPEIRA_INTEGRATION'] == '1'
          skip 'Set EMPEIRA_INTEGRATION=1 to create temporary owned runtime networks'
        end
        runtime = Empeira::Runtime.registry.build(engine, context: apps.first.context, runner: apps.first.runner)
        begin
          runtime.check_available!
        rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
          raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

          skip e.message
        end
      end

      after do
        next unless ENV['EMPEIRA_INTEGRATION'] == '1'

        apps.each do |app|
          persistent = Empeira::Infrastructure::Store.new(context: app.context)
          app.infrastructure.destroy if persistent.load
        end
      end

      it 'verifies lifecycle, backend isolation/labels and preservation of a second workspace' do
        first, second = apps
        resources = apps.map { |app| app.infrastructure.up.resource }
        expect(resources.map(&:id).uniq.size).to eq(2)
        expect(resources.map(&:name).uniq.size).to eq(2)
        apps.zip(resources).each do |app, resource|
          expect(resource.isolated).to be(true)
          expect(resource.labels).to include('io.empeira.workspace' => app.context.workspace.id)
          expect(app.infrastructure.up.changed).to be(false)
          expect(app.infrastructure.status).to include('Infrastructure' => 'up',
                                                       'Infrastructure fingerprint' => 'current')
        end
        apps.each { |app| app.run_node(hostname: 'same-name', provider: 'container') }
        first.nodes.destroy(name: 'same-name')
        expect(second.nodes.list).to include(hash_including('hostname' => 'same-name', 'state' => 'running'))
        second.nodes.destroy(name: 'same-name')
        expect(first.infrastructure.down.changed).to be(true)
        expect(first.infrastructure.down.changed).to be(false)
        expect(second.infrastructure.status['Infrastructure']).to eq('up')
        expect(second.infrastructure.down.changed).to be(true)
        expect(second.infrastructure.down.changed).to be(false)
      end

      it 'persists state across CLI processes and detects a runtime configuration mismatch' do
        app = apps.first
        binary = File.expand_path('../../bin/empeira', __dir__)
        # Keep test state temporary on macOS too, without changing the engine's HOME/configuration.
        launcher = <<~RUBY
          require 'empeira'
          test_home = ARGV.shift
          Empeira::Platform::Locations.define_singleton_method(:new) do |**options|
            super(**options, home: test_home, environment: {})
          end
          load ARGV.shift
        RUBY
        invoke = lambda do |command, selected_engine = engine|
          app.runner.run(RbConfig.ruby,
                         arguments: ['-I', File.expand_path('../../lib', __dir__), '-e', launcher, locations.home.to_s,
                                     binary, command,
                                     '--container-engine', selected_engine],
                         directory: app.context.project.path, timeout: 600)
        end
        begin
          expect(invoke.call('up')).to be_success
          expect(app.infrastructure.status['Infrastructure']).to eq('up')
          expect(invoke.call('status').stdout).to include('Infrastructure: up', 'Infrastructure fingerprint: current')
          expect(invoke.call('up')).to be_success
          other = (Empeira::Runtime.registry.names - [engine]).first
          mismatch = invoke.call('down', other)
          expect(mismatch).not_to be_success
          expect(mismatch.stderr).to include("belongs to #{engine}")
          expect(invoke.call('status').stdout).to include('Infrastructure: up')
          expect(invoke.call('down')).to be_success
          expect(invoke.call('down')).to be_success
        ensure
          expect(invoke.call('destroy')).to be_success
        end
      end
    end
  end
end
