# frozen_string_literal: true

require 'openssl'
require_relative '../support/openvox_smoke'

RSpec.describe 'Real container nodes', :integration do
  include OpenVoxSmoke

  Empeira::Runtime.registry.names.each do |engine|
    context engine do
      let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
      let(:project) { File.join(@directory, 'control') }
      let(:app) do
        Empeira::Application.new(project_path: project, locations: locations,
                                 overrides: { 'runtime' => { 'container_engine' => engine } })
      end
      let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

      before do
        skip 'Set EMPEIRA_INTEGRATION=1 for actual container nodes' unless ENV['EMPEIRA_INTEGRATION'] == '1'
        initialize_project(project)
        FileUtils.mkdir_p(File.join(project, 'manifests'))
        runtime.check_available!
      rescue Empeira::Runtime::Unavailable, Empeira::Runtime::UnsupportedCapability => e
        raise if ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', '').split(',').include?(engine)

        skip e.message
      end

      after do |example|
        next unless ENV['EMPEIRA_INTEGRATION'] == '1' && File.directory?(project)

        openvox_diagnostics if example.exception
        app.infrastructure.destroy
        verify_workspace_cleanup
      end

      it 'runs the default OpenVox node with retained state, live code, certificate cleanup and hostname reuse',
         :openvox_smoke do
        File.write(File.join(project, '.empeira.yaml'), '')
        current = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine } })
        prepare_smoke_hiera
        File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
          file { '/tmp/empeira-managed': content => lookup('smoke_content') }
          file { '/tmp/empeira-provider': content => $facts['empeira']['provider'] }
        PUPPET
        current.infrastructure.up
        current.run_node(hostname: 'test-node', provider: 'container')
        expect { current.run_node(hostname: 'TEST-node', provider: 'container') }
          .to raise_error(Empeira::Providers::AlreadyExists)
        resource = node(current)
        expect(current.nodes.list).to include(hash_including('hostname' => 'test-node', 'state' => 'running'))
        expect(runtime.service_exec(resource, %w[cat /tmp/empeira-managed]).stdout).to eq('first')
        expect(runtime.service_exec(resource, %w[cat /tmp/empeira-provider]).stdout).to eq('container')
        expect(current.nodes.list.first.fetch('last_puppet_exit')).to eq(2)
        verify_default_agent(resource)
        verify_node_certificate(resource)
        expect(current.nodes.puppet(name: 'test-node').exit_status).to eq(0)
        verify_puppetdb_smoke
        expect(runtime.service_exec(resource, ['cat', Empeira::Node::ExternalFact::PATH]).stdout)
          .to eq(Empeira::Node::ExternalFact.content('container'))
        current.nodes.stop(name: 'test-node')
        expect(current.nodes.list.first['state']).to eq('stopped')
        current.nodes.start(name: 'test-node')
        expect(node(current)['id']).to eq(resource['id'])
        expect(runtime.service_exec(node(current), %w[cat /tmp/empeira-managed]).stdout).to eq('first')
        File.write(File.join(project, 'manifests/site.pp'),
                   "file { '/tmp/empeira-managed': content => 'uncommitted' }\n" \
                   "file { '/tmp/empeira-provider': content => $facts['empeira']['provider'] }\n")
        current.nodes.puppet(name: 'test-node')
        expect(runtime.service_exec(node(current), %w[cat /tmp/empeira-managed]).stdout).to eq('uncommitted')
        expect(runtime.service_exec(node(current), %w[cat /tmp/empeira-provider]).stdout).to eq('container')
        server = runtime.inspect_service(Empeira::Services::Definition.new(key: 'server',
                                                                           workspace: current.context.workspace))
        health = Empeira::ControlPlane::Health.new(runtime: runtime,
                                                   plan: Empeira::ControlPlane::Plan.new(context: current.context))
        result = runtime.service_exec(server, [*health.http_curl, 'http://puppetdb.empeira.internal:8080/pdb/query/v4/nodes/test-node'])
        persisted = JSON.parse(result.stdout)
        expect(persisted.fetch('certname')).to eq('test-node')
        expect(persisted.fetch('catalog_timestamp')).not_to be_nil
        expect(persisted.fetch('report_timestamp')).not_to be_nil
        expect { current.infrastructure.down }.to raise_error(Empeira::Error, /Nodes exist/)
        current.nodes.destroy(name: 'test-node')
        expect(current.nodes.list).to be_empty
        current.run_node(hostname: 'test-node', provider: 'container')
        expect(node(current)['id']).not_to eq(resource['id'])
        current.nodes.destroy(name: 'test-node')
        current.infrastructure.down
        current.infrastructure.up
        relay = Empeira::Server::RelayCertificate.new(context: current.context)
        previous_certificate = File.binread(relay.path('cert.pem'))
        current.infrastructure.destroy
        expect(File.exist?(relay.path('cert.pem'))).to be(false)
        expect(File.exist?(relay.path('key.pem'))).to be(false)
        current.infrastructure.up
        server = runtime.inspect_service(Empeira::Services::Definition.new(key: 'server',
                                                                           workspace: current.context.workspace))
        ca = runtime.service_exec(server, %w[cat /etc/puppetlabs/puppet/ssl/certs/ca.pem])
        expect(ca).to be_success
        certificate = OpenSSL::X509::Certificate.new(File.binread(relay.path('cert.pem')))
        expect(certificate.to_pem).not_to eq(previous_certificate)
        expect(certificate.verify(OpenSSL::X509::Certificate.new(ca.stdout).public_key)).to be(true)
        current.run_node(hostname: 'new-ca-node', provider: 'container')
        expect(current.nodes.puppet(name: 'new-ca-node').exit_status).to eq(0)
        current.infrastructure.destroy
      end

      it 'installs the default signed DNF agent and removes temporary bootstrap configuration' do
        File.write(File.join(project, '.empeira.yaml'), YAML.dump('puppetdb' => { 'enabled' => false },
                                                                  'node_defaults' => { 'os' => 'rocky',
                                                                                       'version' => '9' }))
        current = Empeira::Application.new(project_path: project, locations: locations,
                                           overrides: { 'runtime' => { 'container_engine' => engine } })
        File.write(File.join(project, 'manifests/site.pp'), "file { '/tmp/empeira-dnf': content => 'managed' }\n")
        current.infrastructure.up
        current.run_node(hostname: 'dnf-node', provider: 'container')
        definition = Empeira::Node::Definition.new(hostname: 'dnf-node', workspace: app.context.workspace)
        resource = runtime.inspect_service(definition)
        expect(runtime.service_exec(resource, %w[cat /tmp/empeira-dnf]).stdout).to eq('managed')
        expect(current.nodes.puppet(name: 'dnf-node').exit_status).to eq(0)
        source = app.context.configuration.dig('agent', 'install', 'repositories', 'el9')
        # rubocop:disable-next Style/FormatStringToken -- RPM queryformat is not Ruby formatting.
        version = runtime.service_exec(resource, ['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}',
                                                  app.context.configuration.dig('agent', 'package')])
        expect(version).to be_success
        expect(version.stdout).to eq("#{app.context.configuration.dig('agent', 'version')}#{source.fetch('suffix')}")
        [Empeira::Node::PackageProxy::DNF_PATH, Empeira::Node::DnfAgentRepository::REPO_PATH,
         Empeira::Node::AgentRepository::CURL_CONFIG_PATH, '/var/tmp/empeira-agent-release.rpm'].each do |path|
          expect(runtime.service_exec(resource, ['test', '!', '-e', path])).to be_success
        end
      end

      def node(current)
        definition = Empeira::Node::Definition.new(hostname: 'test-node', workspace: current.context.workspace)
        runtime.inspect_service(definition)
      end
    end
  end
end
