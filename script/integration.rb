# frozen_string_literal: true

require_relative '../lib/empeira'

# Each invocation selects one runtime and one explicit scope. Full is container-only.
scope = ENV.fetch('EMPEIRA_TEST_SCOPE', 'containers')
runtime = ENV.fetch('EMPEIRA_REQUIRED_RUNTIMES', 'podman')
abort 'Select exactly one runtime: docker or podman' unless %w[docker podman].include?(runtime)
suites = {
  'containers' => [%w[runtime node], 'EMPEIRA_INTEGRATION', '1'],
  'services' => [%w[control_plane additional_configuration], 'EMPEIRA_INTEGRATION', '1'],
  'nodes' => [%w[node], 'EMPEIRA_INTEGRATION', '1'],
  'network' => [%w[direct_egress], 'EMPEIRA_INTEGRATION', 'direct-egress'],
  'images' => [%w[image_freshness registry_auth], 'EMPEIRA_INTEGRATION', 'images'],
  'lifecycle' => [%w[smoke], 'EMPEIRA_INTEGRATION', 'smoke'],
  'mounts' => [%w[server_mounts], 'EMPEIRA_INTEGRATION', 'mounts'],
  'development' => [%w[development_cycle], 'EMPEIRA_INTEGRATION', 'development'],
  'node-tools' => [%w[node_tools], 'EMPEIRA_INTEGRATION', 'node-tools'],
  'modules' => [%w[modules], 'EMPEIRA_INTEGRATION', 'modules'],
  'update-plane' => [%w[update_plane], 'EMPEIRA_INTEGRATION', 'update-plane'],
  'browser' => [%w[browser], 'EMPEIRA_BROWSER_INTEGRATION', '1'],
  'vm' => [%w[vm vm_proxy], 'EMPEIRA_VM_INTEGRATION', '1'],
  'shared-network' => [%w[peer_network], 'EMPEIRA_PEER_NETWORK', '1']
}
full = %w[containers services network images lifecycle mounts development node-tools modules update-plane browser]
abort "Unknown integration scope: #{scope}" unless scope == 'full' || suites.key?(scope)
selected = (scope == 'full' ? full : [scope]).map { |key| suites.fetch(key) }
if %w[network full].include?(scope) && runtime == 'docker'
  selected << [%w[dns_additional_resolver], 'EMPEIRA_INTEGRATION', '1']
end
runner = Empeira::Execution::Runner.new
selected.each do |files, gate, value|
  environment = { gate => value, 'EMPEIRA_VM_RUNTIME' => runtime }
  environment['EMPEIRA_VM_PROXY_INTEGRATION'] = '1' if files.include?('vm_proxy')
  arguments = ['exec', 'rspec', *files.map { |name| "spec/integration/#{name}_spec.rb" }]
  arguments += ['--example', runtime] unless %w[vm peer_network dns_additional_resolver].intersect?(files)
  result = runner.stream('bundle', arguments: arguments, environment: environment)
  exit(result.exit_status || 1) unless result.success?
end
