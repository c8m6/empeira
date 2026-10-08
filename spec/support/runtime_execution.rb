# frozen_string_literal: true

# Synthetic CLI responses, shaped independently for each runtime.
class RuntimeExecution
  attr_reader :networks, :calls
  attr_accessor :failure, :isolation, :attachments

  def initialize
    @networks = Hash.new { |hash, key| hash[key] = {} }
    @calls = []
    @isolation = true
    @attachments = 0
    @sequence = 0
  end

  def run(engine, arguments:, **)
    return Empeira::Execution::Runner.new.run(engine, arguments: arguments, **) if engine == 'git'
    return Empeira::Execution::Result.new(stdout: '[]', stderr: '', exit_status: 0, timed_out: false) if engine == 'ip'

    calls << [engine, arguments]
    value = dispatch(engine, arguments)
    Empeira::Execution::Result.new(stdout: value, stderr: '', exit_status: 0, timed_out: false)
  end

  # Explicit synthetic CLI dispatcher keeps fixtures independent of adapter parsing.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
  def dispatch(engine, arguments)
    case arguments.take(2)
    when ['info', '--format'] then JSON.generate(info(engine))
    when %w[network ls] then listing(engine)
    when %w[network inspect] then JSON.generate([networks[engine].fetch(arguments.last)])
    when %w[network create] then create(engine, arguments)
    when %w[network rm] then networks[engine].delete(arguments.last) && arguments.last
    when ['ps', '--all'] then JSON.generate(Array.new(attachments) { {} })
    else raise "Unexpected runtime command #{arguments.inspect}"
    end
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

  def info(engine)
    if engine == 'docker'
      { 'ServerVersion' => '28.0.0', 'OSType' => 'linux', 'Plugins' => { 'Network' => ['bridge'] } }
    else
      { 'host' => { 'networkBackend' => 'netavark' }, 'plugins' => { 'network' => ['bridge'] } }
    end
  end

  def listing(engine)
    if engine == 'docker'
      networks[engine].values.map { |data| JSON.generate('ID' => data['Id'], 'Name' => data['Name']) }.join("\n")
    else
      JSON.generate(networks[engine].values)
    end
  end

  def create(engine, arguments)
    @sequence += 1
    id = "synthetic-#{@sequence}"
    labels = arguments.each_cons(2).filter_map { |flag, value| value.split('=', 2) if flag == '--label' }.to_h
    networks[engine][id] = network_data(engine, id, arguments.last, labels)
    fail_creation!

    id
  end

  def fail_creation!
    raise Interrupt if failure == :interrupt
    raise Empeira::Providers::ExecutionError, 'synthetic timeout' if failure == :timeout
    raise Empeira::Providers::ExecutionError, 'synthetic failure after create' if failure == :error
  end

  def network_data(engine, id, name, labels)
    if engine == 'docker'
      { 'Id' => id, 'Name' => name, 'Labels' => labels, 'Internal' => isolation, 'Driver' => 'bridge',
        'Options' => { 'com.docker.network.bridge.gateway_mode_ipv4' => 'isolated',
                       'com.docker.network.bridge.gateway_mode_ipv6' => 'isolated' },
        'Containers' => {} }
    else
      { 'id' => id, 'name' => name, 'labels' => labels, 'internal' => isolation, 'driver' => 'bridge',
        'options' => { 'isolate' => 'true' }, 'dns_enabled' => false }
    end
  end

  def mutations
    calls.select { |_engine, arguments| %w[create rm].include?(arguments[1]) }
  end
end
