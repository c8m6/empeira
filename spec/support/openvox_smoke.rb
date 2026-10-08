# frozen_string_literal: true

require_relative 'puppetdb_queries'

# rubocop:disable Metrics/AbcSize -- These helpers assert multiple observations across the real runtime boundary.
module OpenVoxSmoke
  include PuppetDBQueries

  def prepare_smoke_hiera
    FileUtils.mkdir_p(File.join(project, 'data'))
    File.write(File.join(project, 'hiera.yaml'), YAML.dump(
                                                   'version' => 5, 'defaults' => { 'datadir' => 'data',
                                                                                   'data_hash' => 'yaml_data' },
                                                   'hierarchy' => [{ 'name' => 'Common', 'path' => 'common.yaml' }]
                                                 ))
    File.write(File.join(project, 'data/common.yaml'), YAML.dump('smoke_content' => 'first'))
  end

  def verify_default_agent(resource)
    config = app.context.configuration
    expect(runtime.service_exec(resource, %w[cat /etc/os-release]).stdout).to include('VERSION_ID="24.04"')
    version = runtime.service_exec(resource, ['dpkg-query', '-W', '-f', '${Version}', config.dig('agent', 'package')])
    expect(version).to be_success
    expect(version.stdout).to eq(config.dig('agent', 'version') + config.dig('agent', 'install', 'repositories',
                                                                             'ubuntu24.04', 'suffix'))
  end

  def verify_node_certificate(resource)
    certificate = runtime.service_exec(resource, %w[cat /etc/puppetlabs/puppet/ssl/certs/test-node.pem])
    ca = runtime.service_exec(resource, %w[cat /etc/puppetlabs/puppet/ssl/certs/ca.pem])
    expect(certificate).to be_success
    expect(ca).to be_success
    expect(OpenSSL::X509::Certificate.new(certificate.stdout)
      .verify(OpenSSL::X509::Certificate.new(ca.stdout).public_key)).to be(true)
  end

  # rubocop:disable-next Metrics/MethodLength -- Verify the real catalog and both reports as one E2E boundary.
  def verify_puppetdb_smoke
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    server = runtime.inspect_service(plan.definitions.fetch('server'))
    health = Empeira::ControlPlane::Health.new(runtime: runtime, plan: plan)
    %w[server postgres puppetdb-backend puppetdb].each do |key|
      expect(health.ready?(key, runtime.inspect_services(plan.definitions))).to be(true)
    end
    endpoint = 'http://puppetdb.empeira.internal:8080/pdb/query/v4'
    catalog = JSON.parse(query_until(server, [*health.http_curl, "#{endpoint}/catalogs/test-node"]))
    resource = hash_including('type' => 'File', 'title' => '/tmp/empeira-managed',
                              'parameters' => hash_including('content' => 'first'))
    expect(catalog.fetch('resources').fetch('data')).to include(resource)
    %w[changed unchanged].each do |status|
      query = JSON.generate(['and', ['=', 'certname', 'test-node'], ['=', 'status', status]])
      reports = JSON.parse(query_until(server, [*health.http_curl, '--get', '--data-urlencode', "query=#{query}",
                                                "#{endpoint}/reports"]))
      expect(reports).to include(hash_including('certname' => 'test-node', 'status' => status))
    end
  end

  def verify_workspace_cleanup
    expect(Empeira::Infrastructure::Store.new(context: app.context).load).to be_nil
    filter = "label=io.empeira.workspace=#{app.context.workspace.id}"
    [%w[ps --all --quiet], %w[network ls --quiet], %w[volume ls --quiet]].each do |arguments|
      result = app.runner.run(runtime.name, arguments: [*arguments, '--filter', filter])
      expect(result).to be_success
      expect(result.stdout.strip).to be_empty, "Owned #{arguments.first} resources remain after destroy"
    end
  end

  def openvox_diagnostics
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    runtime.inspect_services(plan.definitions).each do |key, resource|
      next unless resource

      logs = app.runner.run(runtime.name, arguments: ['logs', '--tail', '60', resource.fetch('id')], timeout: 10)
      warn "#{key} (#{resource.fetch('state')}): #{Empeira::Execution::Diagnostics.clean(logs.stdout + logs.stderr)}"
    end
  rescue Empeira::Error => e
    warn "Smoke diagnostics unavailable: #{Empeira::Execution::Diagnostics.clean(e.message)}"
  end
end

# rubocop:enable Metrics/AbcSize
