# frozen_string_literal: true

RSpec.describe 'Shared runtime service-image contract' do
  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:recipe) { Empeira::Images::Configuration.recipe({ 'build' => 'proxy/Containerfile' }) }
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: runner) }

      def result(stdout: '', code: 0)
        Empeira::Execution::Result.new(stdout: stdout, stderr: '', exit_status: code, timed_out: false)
      end

      it 'reuses only a local image labeled with the exact reviewed recipe hash' do
        recipe = Empeira::Images::Configuration.recipe({ 'build' => 'proxy/Containerfile' })
        metadata = [{ 'Config' => { 'Labels' => { 'io.empeira.recipe' => Digest::SHA256.hexdigest(recipe) } } }]
        allow(runner).to receive(:run).and_return(result(stdout: JSON.generate(metadata)))
        expect do
          runtime.ensure_image(Empeira::Images::Configuration.local_image(recipe), recipe: recipe)
        end.not_to raise_error
        metadata.first['Config']['Labels']['io.empeira.recipe'] = 'different'
        allow(runner).to receive(:run).and_return(result(stdout: JSON.generate(metadata)))
        expect { runtime.ensure_image(Empeira::Images::Configuration.local_image(recipe), recipe: recipe) }
          .to raise_error(Empeira::Providers::OwnershipError)
      end

      it 'builds in an isolated temporary context without sending the project or credentials' do
        context_path = nil
        allow(runtime).to receive(:base_state).and_return({})
        allow(runner).to receive(:run) do |executable, arguments:, timeout:|
          expect(executable).to eq(engine)
          expect(timeout).to be_positive
          if arguments.first == 'image'
            result(code: 1)
          else
            expect(arguments.first).to eq('build')
            context_path = arguments.last
            expect(Dir.children(context_path)).to eq(['Containerfile'])
            expect(File.read(File.join(context_path,
                                       'Containerfile'))).to eq(recipe)
            result
          end
        end
        runtime.ensure_image(Empeira::Images::Configuration.local_image(recipe),
                             recipe: Empeira::Images::Configuration.recipe({ 'build' => 'proxy/Containerfile' }))
        expect(File).not_to exist(context_path)
      end

      it 'fails closed on malformed recipe inspection metadata' do
        allow(runner).to receive(:run).and_return(result(stdout: '[]'))
        expect { runtime.ensure_image(Empeira::Images::Configuration.local_image(recipe), recipe: Empeira::Images::Configuration.recipe({ 'build' => 'proxy/Containerfile' })) }
          .to raise_error(Empeira::Providers::ExecutionError)
      end
    end
  end
end

RSpec.describe 'Batched service snapshots' do
  %w[docker podman].each do |engine|
    it "inspects five #{engine} services with two calls and retains ID/ownership validation" do
      app = Empeira::Application.new(project_path: @directory)
      definitions = %w[dns server proxy postgres puppetdb].to_h do |key|
        [key, Empeira::Services::Definition.new(key: key, workspace: app.context.workspace)]
      end
      ids = definitions.keys.to_h { |key| [key, "id-#{key}"] }
      data = definitions.map do |key, definition|
        { 'Id' => ids[key], 'Name' => definition.name, 'Config' => { 'Labels' => definition.labels },
          'State' => { 'Status' => 'running' }, 'NetworkSettings' => { 'Networks' => {} }, 'Mounts' => [] }
      end
      runner = instance_double(Empeira::Execution::Runner)
      calls = []
      allow(runner).to receive(:run) do |_, arguments:, **|
        calls << arguments
        output = if arguments.first == 'ps'
                   definitions.map do |key, definition|
                     "#{ids[key]} #{definition.name}\n"
                   end.join
                 else
                   JSON.generate(data)
                 end
        Empeira::Execution::Result.new(stdout: output, stderr: '', exit_status: 0, timed_out: false)
      end
      runtime = Empeira::Runtime.registry.build(engine, context: app.context, runner: runner)
      expect(runtime.inspect_services(definitions, expected_ids: ids).keys).to eq(definitions.keys)
      expect(calls.size).to eq(2)
      expect(calls.last.take(2)).to eq(%w[container inspect])
      expect { runtime.inspect_services(definitions, expected_ids: ids.merge('server' => 'replacement')) }
        .to raise_error(Empeira::Providers::OwnershipError)
      data.first['Name'] = 'renamed'
      expect { runtime.inspect_services(definitions, expected_ids: ids) }.to raise_error(Empeira::Providers::OwnershipError)
    end
  end
end

RSpec.describe 'Transaction inspection safety' do
  %w[docker podman].each do |engine|
    context engine do
      let(:app) { Empeira::Application.new(project_path: @directory) }
      let(:runner) { instance_double(Empeira::Execution::Runner) }
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: runner) }
      let(:definition) { Empeira::Services::Definition.new(key: 'server', workspace: app.context.workspace) }
      let(:data) do
        { 'Id' => 'recorded', 'Name' => definition.name, 'Config' => { 'Labels' => definition.labels },
          'State' => { 'Status' => 'running' }, 'NetworkSettings' => { 'Networks' => {} }, 'Mounts' => [] }
      end

      def inspection(stdout, code = 0)
        Empeira::Execution::Result.new(stdout: stdout, stderr: '', exit_status: code, timed_out: false)
      end

      it 'reads a recorded container directly and rejects altered labels or names without a stale cache' do
        expect(runner).to receive(:run).with(engine, arguments: %w[container inspect recorded], timeout: 30)
                                       .and_return(inspection(JSON.generate([data])))
        expect(runtime.inspect_service(definition, expected_id: 'recorded').fetch('id')).to eq('recorded')
        data['Config']['Labels']['io.empeira.workspace'] = 'foreign'
        expect(runner).to receive(:run).and_return(inspection(JSON.generate([data])))
        expect { runtime.inspect_service(definition, expected_id: 'recorded') }
          .to raise_error(Empeira::Providers::OwnershipError)
        data['Config']['Labels'] = definition.labels
        data['Name'] = 'renamed'
        expect(runner).to receive(:run).and_return(inspection(JSON.generate([data])))
        expect { runtime.inspect_service(definition, expected_id: 'recorded') }
          .to raise_error(Empeira::Providers::OwnershipError)
      end

      it 'rejects a replacement by name after the recorded ID disappears' do
        data['Id'] = 'replacement'
        allow(runner).to receive(:run) do |_, arguments:, **|
          if arguments == %w[container inspect recorded]
            inspection('', 1)
          elsif arguments.first == 'ps'
            inspection("replacement #{definition.name}\n")
          else
            inspection(JSON.generate([data]))
          end
        end
        expect { runtime.inspect_service(definition, expected_id: 'recorded') }
          .to raise_error(Empeira::Providers::OwnershipError)
      end

      it 'batches volume reads and rejects foreign labels, changed IDs and incomplete snapshots' do
        definitions = %w[ca ssl server-data].to_h do |key|
          [key, Empeira::Services::Definition.new(key: key, workspace: app.context.workspace)]
        end
        ids = definitions.keys.to_h { |key| [key, "volume-#{key}"] }
        volumes = definitions.map do |key, entry|
          { 'Name' => entry.name, 'Labels' => entry.labels.merge('io.empeira.volume-id' => ids[key]) }
        end
        calls = []
        allow(runner).to receive(:run) do |_, arguments:, **|
          calls << arguments
          output = if arguments[1] == 'ls'
                     definitions.values.map do |entry|
                       "#{entry.name}\n"
                     end.join
                   else
                     JSON.generate(volumes)
                   end
          inspection(output)
        end
        expect(runtime.inspect_volumes(definitions, expected_ids: ids).size).to eq(3)
        expect(calls.size).to eq(2)
        volumes.first['Labels']['io.empeira.workspace'] = 'foreign'
        expect { runtime.inspect_volumes(definitions, expected_ids: ids) }
          .to raise_error(Empeira::Providers::OwnershipError)
        volumes.first['Labels'] = definitions.fetch('ca').labels.merge('io.empeira.volume-id' => 'replacement')
        expect { runtime.inspect_volumes(definitions, expected_ids: ids) }
          .to raise_error(Empeira::Providers::OwnershipError)
        volumes.pop
        expect { runtime.inspect_volumes(definitions, expected_ids: ids) }
          .to raise_error(Empeira::Providers::ExecutionError)
      end
    end
  end
end

RSpec.describe 'Bounded node network verification' do
  %w[docker podman].each do |engine|
    it "verifies actual #{engine} network identity and isolation with one inspection" do
      app = Empeira::Application.new(project_path: @directory)
      definition = Empeira::Network::Definition.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
      data = if engine == 'docker'
               { 'Id' => 'network-id', 'Name' => definition.backend_name, 'Labels' => definition.labels,
                 'Internal' => true, 'Driver' => 'bridge',
                 'Options' => { 'com.docker.network.bridge.gateway_mode_ipv4' => 'isolated',
                                'com.docker.network.bridge.gateway_mode_ipv6' => 'isolated' } }
             else
               { 'id' => 'network-id', 'name' => definition.backend_name, 'labels' => definition.labels,
                 'internal' => true, 'driver' => 'bridge', 'dns_enabled' => false,
                 'options' => { 'isolate' => 'true' } }
             end
      runner = instance_double(Empeira::Execution::Runner)
      calls = []
      allow(runner).to receive(:run) do |_, arguments:, **|
        calls << arguments
        Empeira::Execution::Result.new(stdout: JSON.generate([data]), stderr: '', exit_status: 0, timed_out: false)
      end
      runtime = Empeira::Runtime.registry.build(engine, context: app.context, runner: runner)
      expect(runtime.verify_isolated_network(definition, expected_id: 'network-id')).to be(true)
      expect(calls).to eq([['network', 'inspect', definition.backend_name]])
      id_key, isolation_key, labels_key = engine == 'docker' ? %w[Id Internal Labels] : %w[id internal labels]
      data[id_key] = 'replacement'
      expect { runtime.verify_isolated_network(definition, expected_id: 'network-id') }
        .to raise_error(Empeira::Providers::OwnershipError)
      data[id_key] = 'network-id'
      data[isolation_key] = false
      expect { runtime.verify_isolated_network(definition, expected_id: 'network-id') }
        .to raise_error(Empeira::Network::UnsupportedPolicy)
      data[isolation_key] = true
      data[labels_key]['io.empeira.workspace'] = 'foreign'
      expect { runtime.verify_isolated_network(definition, expected_id: 'network-id') }
        .to raise_error(Empeira::Providers::OwnershipError)
    end
  end
end
