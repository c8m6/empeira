# frozen_string_literal: true

RSpec.describe 'Native Hiera Empeira selection', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_HIERA_SELECTION_RUNTIME', 'docker') }
  let(:app) do
    Empeira::Application.new(project_path: @directory, overrides: { 'runtime' => { 'container_engine' => engine } })
  end
  let(:runtime) { Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner) }

  before do
    skip 'Set EMPEIRA_HIERA_SELECTION_INTEGRATION=1 for real Puppet/Hiera interpolation' unless
      ENV['EMPEIRA_HIERA_SELECTION_INTEGRATION'] == '1'

    data = Pathname(@directory).join('selection')
    FileUtils.mkdir_p(data.join('virtual'))
    hierarchy = [{ 'name' => 'Provider', 'path' => 'virtual/empeira-%{facts.empeira.provider}.yaml' },
                 { 'name' => 'Empeira common', 'path' => 'virtual/%{facts.empeira.hierarchy}.yaml' },
                 { 'name' => 'Virtualization', 'path' => 'virtual/%{facts.virtual}.yaml' }]
    data.join('hiera.yaml').write(YAML.dump('version' => 5,
                                            'defaults' => { 'datadir' => '.', 'data_hash' => 'yaml_data' },
                                            'hierarchy' => hierarchy))
    %w[vm container].each do |provider|
      data.join("virtual/empeira-#{provider}.yaml").write(
        YAML.dump('fixture::priority' => provider, 'fixture::merge' => [provider])
      )
      data.join("#{provider}.json").write(JSON.generate('virtual' => 'physical',
                                                        'empeira' => { 'provider' => provider,
                                                                       'hierarchy' => 'empeira' }))
    end
    data.join('virtual/empeira.yaml').write(YAML.dump('fixture::priority' => 'common', 'fixture::merge' => ['common'],
                                                      'fixture::common' => 'empeira-only'))
    data.join('virtual/physical.yaml').write(YAML.dump('fixture::priority' => 'regular',
                                                       'fixture::merge' => ['regular']))
    data.join('production.json').write(JSON.generate('virtual' => 'physical'))
    image = Empeira::Images::Configuration.reference(app.context.configuration.dig('images', 'server'))
    runtime.check_available!
    runtime.ensure_image(image)
    @definition = Empeira::Services::Definition.new(key: "hiera-selection-#{SecureRandom.hex(8)}",
                                                    workspace: app.context.workspace, image: image, network: 'none',
                                                    entrypoint: 'sleep', command: ['infinity'], memory: 256,
                                                    mounts: ["type=bind,src=#{data},dst=/fixture,readonly"])
    @resource = runtime.create_service(@definition)
    runtime.start_service(@resource)
    observed = runtime.inspect_service(@definition, expected_id: @resource.fetch('id'))
    expect(observed.fetch('networks').keys).to eq(['none'])
    expect(observed.fetch('ports')).to be_empty
  end

  after do
    runtime.remove_service(@definition, expected_id: @resource.fetch('id')) if @resource
  end

  it 'uses provider/common/virtualization priority and native merges while excluding common data without the fact' do
    version = runtime.service_exec(@resource, ['/opt/puppetlabs/puppet/bin/puppet', '--version'])
    expect(version).to be_success
    puts "Native Puppet/Hiera selection: Puppet #{version.stdout.strip} (#{engine})"
    %w[vm container].each do |provider|
      expect(lookup('fixture::priority', provider)).to eq(provider)
      expect(lookup('fixture::common', provider)).to eq('empeira-only')
      expect(lookup('fixture::merge', provider, '--merge', 'unique')).to eq([provider, 'common', 'regular'])
    end
    expect(lookup('fixture::priority', 'production')).to eq('regular')
    expect(lookup('fixture::merge', 'production', '--merge', 'unique')).to eq(['regular'])
    expect(lookup('fixture::common', 'production', '--default', 'absent')).to eq('absent')
  end

  def lookup(key, facts, *options)
    arguments = ['/opt/puppetlabs/puppet/bin/puppet', 'lookup', key, '--hiera_config', '/fixture/hiera.yaml',
                 '--confdir', '/tmp/lookup-conf', '--vardir', '/tmp/lookup-var', '--codedir', '/tmp/lookup-code',
                 '--logdir', '/tmp/lookup-log', '--rundir', '/tmp/lookup-run',
                 '--facts', "/fixture/#{facts}.json", '--render-as', 'json', *options]
    result = runtime.service_exec(@resource, arguments)
    expect(result).to be_success, result.stderr
    JSON.parse(result.stdout)
  end
end
