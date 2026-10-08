# frozen_string_literal: true

require_relative 'support/eyaml_fixture'

RSpec.describe 'Configuration server runtime contract' do
  def configuration(fragment = {})
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump(fragment))
    Empeira::Application.new(project_path: @directory).context.configuration
  end

  def plan(fragment = {})
    config = configuration(fragment)
    context = Empeira::Application.new(project_path: @directory).context
    expect(context.configuration).to eq(config)
    Empeira::ControlPlane::Plan.new(context: context)
  end

  it 'starts a complete OpenVox control plane from the defaults' do
    value = plan
    runtime = value.server_runtime
    expect(runtime.startup.fetch('arguments')).to eq(['foreground'])
    expect(value.definitions.fetch('server').options.fetch('image'))
      .to eq(Empeira::Images::Configuration.reference(value.config.dig('images', 'server')))
    expect(value.definitions.fetch('puppetdb-backend').options.fetch('image'))
      .to eq(Empeira::Images::Configuration.reference(value.config.dig('images', 'puppetdb')))
    expect(value.definitions.fetch('server').options.fetch('environment'))
      .to include('OPENVOXSERVER_HOSTNAME' => 'server.empeira.internal')
  end

  it 'overrides images independently of the agent package' do
    value = plan('images' => { 'server' => { 'reference' => 'example.org/custom-server:1' },
                               'puppetdb' => { 'reference' => 'example.org/custom-db:1' },
                               'postgres' => { 'reference' => 'example.org/custom-postgres:1' } },
                 'agent' => { 'package' => 'puppet-agent' })
    definitions = value.definitions
    expect(definitions.fetch('server').options.fetch('image')).to eq('example.org/custom-server:1')
    expect(definitions.fetch('puppetdb-backend').options.fetch('image')).to eq('example.org/custom-db:1')
    expect(definitions.fetch('postgres').options.fetch('image')).to eq('example.org/custom-postgres:1')
  end

  it 'supports a focused custom image startup contract' do
    value = plan('server' => { 'runtime' => {
                   'startup' => { 'entrypoint' => '/opt/custom/start', 'arguments' => %w[serve --foreground] },
                   'paths' => { 'puppetdb_config' => '/opt/custom/conf/puppetdb.conf' },
                   'environment_keys' => { 'server_hostname' => 'CUSTOM_SERVER_HOSTNAME' }
                 } })
    server = value.definitions.fetch('server').options
    expect(server.fetch('command')).to end_with('/opt/custom/start', '/opt/custom/conf/puppetdb.conf',
                                                'direct', 'puppetdb', 'serve', '--foreground')
    expect(server.fetch('environment')).to include('CUSTOM_SERVER_HOSTNAME' => 'server.empeira.internal')
  end

  [true, false].product([true, false], %w[direct staged]).each do |database, eyaml_enabled, delivery|
    it "honors startup with PuppetDB=#{database}, EYAML=#{eyaml_enabled}, delivery=#{delivery}" do
      keys = if eyaml_enabled
               EyamlFixture.new(project: @directory,
                                directory: @directory).prepare
             else
               { 'enabled' => false }
             end
      value = plan('puppetdb' => { 'enabled' => database }, 'eyaml' => keys,
                   'server' => { 'runtime' => { 'startup' => {
                     'entrypoint' => '/opt/custom/start', 'arguments' => ['serve'], 'eyaml_keys' => delivery
                   } } })
      server = value.definitions.fetch('server').options
      if database || (eyaml_enabled && delivery == 'staged')
        expect(server.fetch('command')).to include('/opt/custom/start', 'serve')
      else
        expect(server.fetch('entrypoint')).to eq('/opt/custom/start')
        expect(server.fetch('command')).to eq(['serve'])
      end
    end
  end

  it 'uses custom PuppetDB runtime paths and process arguments' do
    value = plan('puppetdb' => { 'runtime' => {
                   'entrypoint' => '/opt/custom/java', 'user' => '1000',
                   'paths' => { 'config' => '/opt/custom/conf', 'data' => '/opt/custom/data' },
                   'java_arguments' => ['-Xmx384m']
                 } })
    database = value.definitions.fetch('puppetdb-backend').options
    expect(database.fetch('entrypoint')).to eq('/opt/custom/java')
    expect(database.fetch('user')).to eq('1000')
    expect(database.fetch('command')).to include('/opt/custom/conf', '/opt/custom/data/restartcounter')
    expect(database.fetch('command')).to include('-Xmx384m')
    expect(database).not_to have_key('environment')
    expect(database.fetch('mounts')).to include(a_string_including('dst=/opt/custom/conf/jetty.ini'))
  end

  it 'rejects removed provider selection and unsafe startup overrides' do
    expect { configuration('server' => { 'type' => 'puppet' }) }
      .to raise_error(Empeira::ConfigurationError, /server.type/)
    expect { configuration('images' => { 'providers' => {} }) }
      .to raise_error(Empeira::ConfigurationError, /images.providers/)
    expect { configuration('server' => { 'runtime' => { 'startup' => { 'entrypoint' => 'relative' } } }) }
      .to raise_error(Empeira::ConfigurationError, /server.runtime.startup.entrypoint/)
    expect { configuration('puppetdb' => { 'runtime' => { 'paths' => { 'data' => '../unsafe' } } }) }
      .to raise_error(Empeira::ConfigurationError, /puppetdb.runtime.paths.data/)
  end
end
