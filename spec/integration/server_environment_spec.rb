# frozen_string_literal: true

RSpec.describe 'Effective server environment configuration', :integration do
  Empeira::Runtime.registry.names.each do |engine|
    [false, true].each do |custom|
      context "#{engine}, custom entrypoint=#{custom}" do
        let(:engine_name) { engine }
        let(:project) { Pathname(@directory).join('control') }
        let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
        let(:app) do
          Empeira::Application.new(project_path: project, locations: locations,
                                   overrides: { 'runtime' => { 'container_engine' => engine } })
        end
        let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

        before do
          skip 'Set EMPEIRA_INTEGRATION=server-environment for real server checks' unless
            ENV['EMPEIRA_INTEGRATION'] == 'server-environment'
          initialize_project(project)
          project.join('manifests').mkpath
          project.join('manifests/site.pp').write("file { '/tmp/environment-value': content => 'first' }\n")
          prepare_custom_server if custom
          runtime.check_available!
          @available = true
        end

        after { app.infrastructure.destroy if @available }

        it 'enforces zero, preserves CA and PuppetDB, and applies edits without up' do
          app.infrastructure.up
          server = service('server')
          expect(setting(server, 'environment_timeout')).to eq('0')
          expect(setting(server, 'strict_variables')).to eq('true') if custom
          ca = runtime.service_exec(server, %w[cat /etc/puppetlabs/puppet/ssl/certs/ca.pem]).stdout
          expect(ca).to include('BEGIN CERTIFICATE')
          app.run_node(hostname: 'environment-node', provider: 'container')
          node = runtime.inspect_service(Empeira::Node::Definition.new(hostname: 'environment-node',
                                                                       workspace: app.context.workspace))
          expect(runtime.service_exec(node, %w[cat /tmp/environment-value]).stdout).to eq('first')
          project.join('manifests/site.pp').write("file { '/tmp/environment-value': content => 'changed' }\n")
          expect([0, 2]).to include(app.nodes.puppet(name: 'environment-node').exit_status)
          expect(runtime.service_exec(node, %w[cat /tmp/environment-value]).stdout).to eq('changed')
          expect(app.infrastructure.up.changed).to be(false)
          expect(service('server').fetch('id')).to eq(server.fetch('id'))
          expect(runtime.service_exec(server, %w[cat /etc/puppetlabs/puppet/ssl/certs/ca.pem]).stdout).to eq(ca)
          result = runtime.service_exec(server, [*Empeira::Server::HTTP.arguments,
                                                 'http://puppetdb.empeira.internal:8080/pdb/query/v4/nodes'])
          expect(result).to be_success
          expect(JSON.parse(result.stdout)).to include(hash_including('certname' => 'environment-node'))
        end

        def service(key)
          runtime.inspect_service(Empeira::Services::Definition.new(key: key, workspace: app.context.workspace))
        end

        def setting(server, name)
          result = runtime.service_exec(server, ['/opt/puppetlabs/bin/puppet', 'config', 'print', name,
                                                 '--section', 'server'])
          expect(result).to be_success
          result.stdout.strip
        end

        # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Build one isolated image with independent startup.
        def prepare_custom_server
          bootstrap = Empeira::Application.new(project_path: project, locations: locations,
                                               overrides: { 'runtime' => { 'container_engine' => engine_name } })
          builder = Empeira::Runtime.registry.build(engine_name, context: bootstrap.context, runner: bootstrap.runner)
          base = Empeira::Images::Configuration.reference(bootstrap.context.configuration.dig('images', 'server'))
          recipe = "FROM #{base}\nCOPY --chmod=0755 custom-entrypoint.sh /custom-entrypoint.sh\n"
          reference = Empeira::Images::Configuration.local_image(recipe, purpose: 'server-environment-fixture')
          # This entrypoint initializes the image normally but ignores the timeout mapping.
          script = <<~SH
            #!/bin/bash
            set -eu
            export OPENVOXSERVER_ENVIRONMENT_TIMEOUT=unlimited
            for hook in /container-entrypoint.d/*.sh; do
              case "$hook" in */83-environment-cache.sh) continue ;; esac
              "$hook"
            done
            /opt/puppetlabs/bin/puppet config set strict_variables true --section server
            exec /opt/puppetlabs/bin/puppetserver "$@"
          SH
          builder.ensure_image(reference, recipe: recipe, files: { 'custom-entrypoint.sh' => script })
          fragment = {
            'images' => { 'server' => { 'reference' => reference } },
            'server' => { 'runtime' => { 'startup' => { 'entrypoint' => '/custom-entrypoint.sh' } } }
          }
          project.join('.empeira.yaml').write(YAML.dump(fragment))
        end
      end
    end
  end
end
