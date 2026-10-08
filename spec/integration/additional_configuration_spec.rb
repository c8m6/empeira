# frozen_string_literal: true

RSpec.describe 'Real additional service configuration', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:project) { File.join(@directory, 'control') }
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }
      let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
      let(:entry) do
        { 'name' => 'example-api', 'image' => { 'repository' => 'docker.io/library/busybox', 'tag' => '1.37.0' },
          'command' => %w[sleep 300],
          'configuration' => { 'target' => '/etc/example/config.yaml',
                               'content' => { 'version' => 1, 'items' => [true, nil, 'literal ${HOME}'] } } }
      end

      before do
        skip 'Set EMPEIRA_INTEGRATION=1 for generated configuration mounts' unless ENV['EMPEIRA_INTEGRATION'] == '1'
        initialize_project(project)
        File.write(File.join(project, '.empeira.yaml'), YAML.dump('containers' => { 'additional' => [entry] }))
        runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do
        runtime.remove_service(@definition, expected_id: @resource&.fetch('id')) if @definition
        runtime.remove_network(definition: @network, expected_id: @network_id) if @network
        plan.additional_configurations.cleanup if @definition
      end

      it 'reads generated YAML as an unprivileged container user and enforces the read-only mount' do
        @network = Empeira::Network::Definition.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
        @network_id = runtime.create_network(definition: @network).resource.id
        plan.additional_configurations.prepare
        @definition = plan.additional_services(network: plan.network, user: '65534:65534').fetch('example-api')
        runtime.ensure_image(@definition.options.fetch('image'))
        @resource = runtime.create_service(@definition)
        runtime.start_service(@resource)
        read = runtime.service_exec(@resource, ['cat', entry.dig('configuration', 'target')])
        expect(read).to be_success
        expect(YAML.safe_load(read.stdout)).to eq(entry.dig('configuration', 'content'))
        write = runtime.service_exec(@resource, ['touch', entry.dig('configuration', 'target')])
        expect(write).not_to be_success
        expect(write.stderr).to match(/read.only/i)
        file = plan.additional_configurations.path(entry)
        expect(file.realpath.to_s).to start_with("#{locations.workspace(app.context.workspace)}/")
      end
    end
  end
end
