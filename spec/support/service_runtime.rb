# frozen_string_literal: true

require_relative 'runtime_proxy_guest'

# rubocop:disable-next Metrics/ClassLength -- Shared observed runtime fixture covers network and service lifecycle.
class ServiceRuntime
  include RuntimeProxyFixture

  attr_reader :services, :volumes, :networks, :calls
  attr_accessor :failure

  def initialize
    @services = {}
    @volumes = {}
    @networks = {}
    @calls = []
  end

  def node_ssh_publication?
    true
  end

  def with_local_images
    yield
  end

  def image_id(_image)
    nil
  end

  def ensure_image(image, **)
    calls << [:image, image]
  end

  def inspect_service(definition, expected_id: nil)
    resource = services[definition.key]
    definition.verify!(resource, expected_id: expected_id)
    resource
  end

  def inspect_services(definitions, expected_ids: {})
    definitions.to_h { |key, definition| [key, inspect_service(definition, expected_id: expected_ids[key])] }
  end

  def inspect_volume(definition, expected_id: nil)
    resource = volumes[definition.key]
    definition.verify!(resource, expected_id: expected_id)
    resource
  end

  def inspect_volumes(definitions, expected_ids: {})
    definitions.to_h { |key, definition| [key, inspect_volume(definition, expected_id: expected_ids[key])] }
  end

  def create_volume(definition)
    calls << [:volume, definition.key]
    volumes[definition.key] = identity(definition)
  end

  # rubocop:disable-next Metrics/AbcSize -- Model the complete observed resource for lifecycle tests.
  def create_service(definition)
    calls << [:create, definition.key]
    options = definition.options
    address = options['runtime_ip'] || options['ip'] || "172.20.0.#{services.size + 128}"
    services[definition.key] = identity(definition).merge(
      'state' => 'created',
      'networks' => { options.fetch('network') => { 'IPAddress' => address } },
      'ports' => {}, 'published_ports' => {}, 'dns' => options['dns'] ? [options['dns']] : []
    )
    if options['ports']&.any?
      port = options['ports'].first.delete_prefix('127.0.0.1::')
      services[definition.key]['ports'] = { port => [{ 'HostIp' => '127.0.0.1', 'HostPort' => '32124' }] }
      services[definition.key]['published_ports'] = services[definition.key]['ports']
    end
    raise Empeira::Providers::ExecutionError, 'synthetic uncertain creation' if failure == definition.key

    services.fetch(definition.key)
  end

  def start_service(resource)
    calls << [:start, resource.fetch('name')]
    resource['state'] = 'running'
  end

  # rubocop:disable-next Naming/PredicateMethod -- Match the mutating runtime contract.
  def remove_service(definition, expected_id: nil)
    inspect_service(definition, expected_id: expected_id)
    calls << [:remove, definition.key]
    !!services.delete(definition.key)
  end

  def remove_volume(definition, expected_id:)
    inspect_volume(definition, expected_id: expected_id)
    volumes.delete(definition.key)
  end

  def reload_service(resource, signal: 'HUP')
    calls << [:reload, resource.fetch('id'), signal]
  end

  def service_exec(resource, arguments, **)
    calls << [:exec, arguments]
    proxy_result = runtime_proxy_result(arguments, resource['name'] || resource['id'])
    return proxy_result if proxy_result

    output = ''
    output = "[main]\ngpgcheck=1\n" if arguments == ['cat', '/etc/dnf/dnf.conf']
    output = "tcp-redirects-v1\n" if arguments == [Empeira::Network::Gateway::EXECUTABLE, 'redirects-capability']
    Empeira::Execution::Result.new(stdout: output, stderr: '', exit_status: 0, timed_out: false)
  end

  def copy_from(_resource, _source, destination)
    File.write(destination, 'synthetic certificate fixture')
  end

  def copy_to(_resource, _source, destination)
    calls << [:copy, destination]
  end

  def inspect_network(identifier:)
    networks[identifier]
  end

  # rubocop:disable-next Naming/PredicateMethod -- Verification raises on failure.
  def verify_isolated_network(definition, expected_id:)
    resource = inspect_network(identifier: definition.backend_name)
    definition.verify_ownership!(resource, expected_id: expected_id)
    definition.verify_definition!(resource) if resource
    definition.verify_isolation!(resource)
    true
  end

  def create_network(definition:)
    resource = Empeira::Network::Resource.new(id: SecureRandom.hex(12), name: definition.backend_name,
                                              labels: definition.labels, isolated: false, attachment_count: 0)
    networks[definition.backend_name] = resource
    Empeira::Providers::Result.new(resource: resource, changed: true)
  end

  def remove_network(definition:, expected_id: nil)
    definition.verify_ownership!(networks[definition.backend_name], expected_id: expected_id)
    changed = !networks.delete(definition.backend_name).nil?
    Empeira::Providers::Result.new(resource: nil, changed: changed)
  end

  def reconcile_workspace_bridge(**options)
    calls << [:bridge, options.fetch(:action)]
  end

  def configure_workspace_route(resource, gateway:, image:)
    calls << [:route, resource.fetch('id'), gateway, image]
  end

  def stop_service(resource)
    calls << [:stop, resource.fetch('id')]
    resource['state'] = 'stopped'
  end

  def detach_egress(definition, resource)
    resource['networks'].delete(definition.backend_name)
  end

  def attach_egress(definition, resource)
    resource['networks'][definition.backend_name] = { 'IPAddress' => '172.21.0.2' }
  end

  private

  def identity(definition)
    { 'id' => SecureRandom.hex(12), 'name' => definition.name, 'labels' => definition.labels }
  end
end
