# frozen_string_literal: true

# Stateful guest model: reads observe mutations, including changes whose SSH result is lost.
class VMNetworkGuest
  attr_reader :links, :addresses, :routes, :commands
  attr_accessor :failure, :facter_output

  def initialize
    @links = {}
    @addresses = {}
    @routes = []
    @commands = []
    @next_index = 10
    add_foreign('eth0', '10.203.20.100/24')
    add_foreign('eth1', '10.0.2.15/24')
    @routes << { 'dst' => 'default', 'gateway' => '10.203.20.1', 'dev' => 'eth0', 'protocol' => 'static' }
  end

  def add_foreign(name, network = nil)
    @next_index += 1
    @links[name] = { 'ifname' => name, 'ifindex' => @next_index, 'flags' => ['UP'], 'operstate' => 'UP' }
    @addresses[name] = []
    address(name, network) if network
  end

  def address(name, network)
    ip, prefix = network.split('/')
    @addresses.fetch(name) << { 'family' => 'inet', 'local' => ip, 'prefixlen' => prefix.to_i }
    subnet = IPAddr.new(network)
    @routes << { 'dst' => "#{subnet}/#{subnet.prefix}", 'dev' => name, 'protocol' => 'kernel', 'scope' => 'link' }
    @routes << { 'dst' => ip, 'type' => 'local', 'dev' => name, 'protocol' => 'kernel', 'table' => 'local',
                 'scope' => 'host' }
  end

  def run(_record, arguments, **)
    @commands << arguments
    fail_now = @failure&.fetch(:match)&.call(arguments)
    return fail_command if fail_now && !@failure[:after]

    stdout = dispatch(arguments)
    return fail_command if fail_now

    result(stdout)
  end

  def fail_command
    failure = @failure
    @failure = nil
    raise failure.fetch(:error) if failure.key?(:error)

    result('', status: 1, stderr: 'synthetic netlink failure')
  end

  def dispatch(arguments)
    case arguments
    when %w[ip -j -d link show] then JSON.generate(@links.values)
    when %w[ip -j address show]
      JSON.generate(@addresses.map { |name, addresses| { 'ifname' => name, 'addr_info' => addresses } })
    when %w[ip -j -4 route show table all] then JSON.generate(@routes)
    when ['/opt/puppetlabs/bin/facter', 'networking', '--json'] then @facter_output || facts
    else mutate(arguments)
    end
  end

  def mutate(arguments)
    case arguments.first(3)
    when %w[ip link add] then create(arguments)
    when %w[ip link delete]
      name = arguments.last
      @links.delete(name)
      @addresses.delete(name)
      @routes.reject! { |route| route['dev'] == name }
    when %w[ip address add] then address(arguments.last, arguments[3])
    when %w[ip link set] then update_link(arguments)
    end
    ''
  end

  def update_link(arguments)
    link = @links.fetch(arguments[4])
    if arguments[5] == 'alias'
      link['ifalias'] = arguments[6]
    else
      link.merge!('flags' => %w[UP LOWER_UP], 'operstate' => 'UNKNOWN')
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Model one atomic netlink creation.
  def create(arguments)
    name = arguments[4]
    raise "duplicate interface #{name}" if @links.key?(name)

    add_foreign(name)
    link = @links.fetch(name)
    link.merge!('address' => arguments[6], 'flags' => [], 'operstate' => 'DOWN')
    type = arguments[arguments.index('type') + 1]
    link['linkinfo'] = { 'info_kind' => type }
    return unless type == 'vlan'

    link['link'] = arguments[arguments.index('type') - 1]
    link['linkinfo']['info_data'] = { 'id' => arguments.last.to_i, 'protocol' => '802.1Q' }
  end

  def facts
    interfaces = @addresses.transform_values do |addresses|
      { 'bindings' => addresses.map do |address|
        { 'address' => address['local'],
          'netmask' => IPAddr.new("#{address['local']}/#{address['prefixlen']}").netmask.to_s }
      end }
    end
    JSON.generate('networking' => { 'interfaces' => interfaces })
  end

  def result(stdout, status: 0, stderr: '')
    Empeira::Execution::Result.new(stdout: stdout, stderr: stderr, exit_status: status, timed_out: false)
  end
end
