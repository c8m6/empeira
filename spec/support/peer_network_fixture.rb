# frozen_string_literal: true

require_relative 'peer_network_checks'
require_relative 'proxy_fixture'

# The test endpoint is standard-library Ruby running in real managed nodes/services.
module ProductionPeerFixture
  include ProductionPeerChecks

  def peer_app
    @peer_app
  end

  def peer_state
    Empeira::Infrastructure::Store.new(context: peer_app.context).load
  end

  def prepare_peer_project
    project = File.join(@directory, 'control')
    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      file { '/var/lib/peer-provider': content => $facts['empeira']['provider'] }
    PUPPET
    @peer_config = { 'puppetdb' => { 'enabled' => false }, 'node_defaults' => { 'memory' => 1024, 'cpus' => 2 } }
    create_peer_application(project)
    prepare_additional_peers(project)
    prepare_peer_ssh
    @peer_canary = ProxyFixture.new(app: peer_app, runtime: @peer_runtime, directory: @directory)
    @peer_canary.start
  end

  def prepare_peer_ssh
    @peer_ssh = vm_guest(peer_app)
  end

  def create_peer_application(project)
    File.write(File.join(project, '.empeira.yaml'), YAML.dump(@peer_config))
    locations = Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                                 environment: { 'XDG_CACHE_HOME' => File.join(
                                                   Dir.home, '.cache'
                                                 ) })
    overrides = { 'runtime' => { 'container_engine' => ENV.fetch('EMPEIRA_VM_RUNTIME', 'podman') } }
    @peer_app = Empeira::Application.new(project_path: project, locations: locations, overrides: overrides)
    prepare_peer_runtime
  end

  def prepare_peer_runtime
    @peer_runtime = Empeira::Runtime.registry.build(peer_app.context.container_engine,
                                                    context: peer_app.context, runner: peer_app.runner)
  end

  def prepare_additional_peers(project)
    image = fixture_image
    @peer_runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
    @peer_config['containers'] = { 'additional' => additional_definitions(image.reference) }
    create_peer_application(project)
  end

  def fixture_image
    request = Empeira::Node::RunRequest.from_config(hostname: 'fixture', provider: 'container',
                                                    config: peer_app.context.configuration)
    Empeira::Node::Image.new(config: peer_app.context.configuration, request: request,
                             architecture: @peer_runtime.architecture)
  end

  def additional_definitions(reference)
    repository, _, tag = reference.rpartition(':')
    %w[echo-service browser-role].map do |name|
      { 'name' => name, 'image' => { 'repository' => repository, 'tag' => tag }, 'command' => %w[sleep infinity] }
    end
  end

  def peer_command(name, arguments)
    if name.start_with?('vm-')
      @peer_ssh.run(peer_state.fetch('nodes').fetch(name), arguments)
    else
      definition = if %w[server echo-service browser-role].include?(name)
                     Empeira::Services::Definition.new(key: name,
                                                       workspace: peer_app.context.workspace)
                   else
                     Empeira::Node::Definition.new(hostname: name, workspace: peer_app.context.workspace)
                   end
      resource = @peer_runtime.inspect_service(definition)
      @peer_runtime.service_exec(resource, arguments, timeout: 15)
    end
  end

  def peer_ruby(name, code, *arguments)
    result = peer_command(name, [Empeira::Node::Certificates::RUBY, '-rsocket', '-e', code, *arguments])
    expect(result).to be_success, "#{name}: #{result.stderr}"
    result.stdout
  end
end
