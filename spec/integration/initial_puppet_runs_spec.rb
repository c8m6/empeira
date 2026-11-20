# frozen_string_literal: true

RSpec.describe 'Repeated initial Puppet runs in real nodes', :integration do
  let(:engine) { ENV.fetch('EMPEIRA_VM_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  let(:events) { [] }
  let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }
  let(:app) do
    Empeira::Application.new(project_path: project, locations: locations, progress: progress,
                             overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  # rubocop:disable-next Metrics/AbcSize -- Read the real count through each provider's native guest access.
  def read_count(provider)
    record = Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch("#{provider}-runs")
    arguments = %w[cat /var/lib/empeira/initial-run-count]
    return vm_guest(app).run(record, arguments) if provider == 'vm'

    runtime = Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner)
    definition = Empeira::Node::Definition.new(hostname: record.fetch('hostname'), workspace: app.context.workspace)
    runtime.service_exec(runtime.inspect_service(definition, expected_id: record.fetch('id')), arguments)
  end

  before do
    skip 'Set EMPEIRA_PUPPET_RUNS_INTEGRATION=1 for real container and VM runs' unless
      ENV['EMPEIRA_PUPPET_RUNS_INTEGRATION'] == '1'

    initialize_project(project)
    File.write(File.join(project, '.empeira.yaml'), YAML.dump('puppetdb' => { 'enabled' => false },
                                                              'node_defaults' => { 'puppet_runs' => 4 }))
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), <<~'PUPPET')
      service { 'puppet': ensure => stopped, enable => false }
      file { '/var/lib/empeira': ensure => directory }
      exec { 'count-initial-runs':
        command => '/bin/sh -c "echo run >> /var/lib/empeira/initial-run-count"',
        require => File['/var/lib/empeira'],
      }
      file { '/etc/puppetlabs/facter/facts.d/initial_ready.txt': content => "initial_ready=true\n" }
      if !$facts['initial_ready'] {
        exec { 'first-run-convergence-failure':
          command => '/bin/false',
          require => [File['/etc/puppetlabs/facter/facts.d/initial_ready.txt'], Exec['count-initial-runs']],
        }
      }
    PUPPET
    Empeira::Runtime.registry.build(engine, context: app.context, runner: app.runner).check_available!
    Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight!
  end

  after do
    next unless ENV['EMPEIRA_PUPPET_RUNS_INTEGRATION'] == '1' && File.directory?(project)

    app.infrastructure.destroy if Empeira::Infrastructure::Store.new(context: app.context).load
  end

  it 'streams a failed first run, completes four runs, and keeps manual Puppet and restart semantics' do
    app.infrastructure.up
    %w[container vm].each do |provider|
      progress.run('Preparing node...') { app.run_node(hostname: "#{provider}-runs", provider: provider) }
      expect(read_count(provider).stdout.lines.size).to eq(4)
      expect(events.select { |event| event.state == :warning }.map(&:message))
        .to include('Puppet run 1/4 finished with exit code 6.')
      events.clear
      expect(app.nodes.puppet(name: "#{provider}-runs").exit_status).to eq(2)
      expect(read_count(provider).stdout.lines.size).to eq(5)
      app.nodes.stop(name: "#{provider}-runs")
      app.nodes.start(name: "#{provider}-runs")
      expect(read_count(provider).stdout.lines.size).to eq(5)
    end
  end
end
