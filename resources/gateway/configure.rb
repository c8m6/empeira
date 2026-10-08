#!/usr/bin/env ruby
# frozen_string_literal: true

require 'ipaddr'
require 'json'
require 'open3'
require 'socket'

# Runs only inside an owned gateway or an ephemeral helper sharing one owned
# container's network namespace. Never modifies host firewall tables or routes.
# rubocop:disable-next Metrics/ModuleLength -- Self-contained, reviewed helper shipped in the gateway image.
module EmpeiraGateway
  module_function

  def command(*arguments, input: nil)
    output, error, status = Open3.capture3(*arguments, **(input ? { stdin_data: input } : {}))
    raise "Gateway operation failed: #{arguments.first}: #{error.lines.last.to_s.strip}" unless status.success?

    output
  end

  def lockdown
    "*filter\n:INPUT DROP [0:0]\n:FORWARD DROP [0:0]\n:OUTPUT DROP [0:0]\n:BOOTSTRAP - [0:0]\nCOMMIT\n"
  end

  def restore(content)
    command('iptables-restore', '--wait', '5', input: content)
  end

  def rules(plan, internal:, external:)
    filter = [':INPUT DROP [0:0]', ':FORWARD DROP [0:0]', ':OUTPUT DROP [0:0]', ':BOOTSTRAP - [0:0]',
              "-A FORWARD -i #{internal} -o #{external} -j BOOTSTRAP"]
    plan.fetch('blocked', []).sort.each { |ip| filter << "-A BOOTSTRAP -s #{ip}/32 -j DROP" }
    filter.concat(dns_rules(plan, internal, external))
    filter.concat(proxy_rules(plan, internal, external))
    filter.concat(direct_rules(plan, internal, external))
    nat = [':PREROUTING ACCEPT [0:0]', ':INPUT ACCEPT [0:0]', ':OUTPUT ACCEPT [0:0]',
           ':POSTROUTING ACCEPT [0:0]',
           "-A POSTROUTING -s #{plan.fetch('subnet')} -o #{external} -j MASQUERADE"]
    "*filter\n#{filter.join("\n")}\nCOMMIT\n*nat\n#{nat.join("\n")}\nCOMMIT\n"
  end

  def dns_rules(plan, internal, external)
    filter = []
    plan.fetch('resolvers').each do |ip|
      %w[tcp udp].each do |protocol|
        filter << "-A FORWARD -i #{internal} -o #{external} -s #{plan.fetch('dns')}/32 " \
                  "-d #{ip}/32 -p #{protocol} --dport 53 -j ACCEPT"
        filter << reply(internal, external, source: plan.fetch('dns'), destination: ip, port: 53, protocol: protocol)
      end
    end
    filter
  end

  def proxy_rules(plan, internal, external)
    filter = []
    plan.fetch('proxies').each do |ip|
      filter << "-A FORWARD -i #{internal} -o #{external} -s #{ip}/32 -p tcp " \
                '-m multiport --dports 80,443 -j ACCEPT'
      [80, 443].each { |port| filter << reply(internal, external, source: ip, port: port) }
    end
    filter
  end

  def direct_rules(plan, internal, external)
    filter = []
    plan.fetch('entries').each do |entry|
      entry.fetch('addresses').each do |ip|
        entry.fetch('ports').each do |port|
          filter << "-A FORWARD -i #{internal} -o #{external} -s #{plan.fetch('subnet')} " \
                    "-d #{ip}/32 -p tcp --dport #{port} -j ACCEPT"
          filter << reply(internal, external, destination: ip, port: port)
        end
      end
    end
    filter
  end

  def reply(internal, external, port:, source: nil, destination: nil, protocol: 'tcp')
    selector = "--ctproto #{protocol} --ctorigdstport #{port}"
    selector += " --ctorigsrc #{source}" if source
    selector += " --ctorigdst #{destination}" if destination
    "-A FORWARD -i #{external} -o #{internal} -m conntrack --ctstate ESTABLISHED,RELATED #{selector} -j ACCEPT"
  end

  def ipv4(value)
    ip = IPAddr.new(value)
    raise 'Gateway requires explicit IPv4 addresses' unless ip.ipv4? && ip.to_s == value

    value
  end

  def validate(plan)
    raise 'Invalid gateway plan version' unless plan.fetch('version') == 1

    subnet = IPAddr.new(plan.fetch('subnet'))
    raise 'Invalid workspace subnet' unless subnet.ipv4? && subnet.private? && subnet.prefix == 24

    validate_addresses(plan, subnet)
    validate_entries(plan.fetch('entries'))
  end

  def validate_addresses(plan, subnet)
    %w[gateway dns].each { |key| raise 'Invalid gateway address' unless subnet.include?(ipv4(plan.fetch(key))) }
    %w[resolvers proxies blocked].each { |key| plan.fetch(key, []).each { |ip| ipv4(ip) } }
  end

  def validate_entries(entries)
    entries.each do |entry|
      entry.fetch('addresses').each { |ip| ipv4(ip) }
      valid = entry.fetch('ports').all? { |port| port.is_a?(Integer) && port.between?(1, 65_535) }
      raise 'Invalid gateway ports' unless valid
    end
  end

  def ipv4_interfaces
    Socket.getifaddrs.select { |entry| entry.addr&.ipv4? && !entry.addr.ipv4_loopback? }
  end

  def interfaces(plan)
    addresses = ipv4_interfaces
    internal = addresses.find { |entry| entry.addr.ip_address == plan.fetch('gateway') }&.name
    external = addresses.map(&:name).uniq.reject { |name| name == internal }
    raise 'Gateway NAT/routing interfaces are unavailable' unless internal && external.size == 1

    [internal, external.first]
  end

  def apply(path)
    restore(lockdown)
    plan = JSON.parse(File.binread(path))
    validate(plan)
    internal, external = interfaces(plan)
    restore(rules(plan, internal: internal, external: external))
  end

  def route(gateway)
    ipv4(gateway)
    interface = ipv4_interfaces.find do |entry|
      IPAddr.new("#{entry.addr.ip_address}/24").include?(gateway)
    end&.name
    raise 'Workspace gateway is not on the attached subnet' unless interface

    command('ip', '-4', 'route', 'flush', 'default')
    command('ip', '-4', 'route', 'replace', 'default', 'via', gateway, 'dev', interface)
  end

  def phase(action, ip)
    ipv4(ip)
    arguments = ['BOOTSTRAP', '-s', "#{ip}/32", '-j', 'DROP']
    _output, _error, exists = Open3.capture3('iptables', '--wait', '5', '-C', *arguments)
    command('iptables', '--wait', '5', action == 'block' ? '-A' : '-D', *arguments) if
      (action == 'block') != exists.success?
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def normalized(content)
    table = nil
    content.lines.each_with_object({}) do |line, result|
      line = line.strip.gsub(/\[\d+:\d+\]/, '[0:0]')
      next if line.empty? || line.start_with?('#') || line == 'COMMIT'

      if line.start_with?('*')
        table = line
      elsif line.start_with?(':')
        result[[table, line.split.first]] = line
      else
        (result[[table, line.split[1]]] ||= []) << normalized_rule(line)
      end
    end
  end

  def normalized_rule(line)
    line.split.each_slice(2).filter_map do |flag, value|
      next if flag == '-m' && %w[tcp udp].include?(value)

      value = value.split(',').sort.join(',') if flag == '--ctstate'
      value = { 'tcp' => '6', 'udp' => '17' }.fetch(value, value) if flag == '--ctproto'
      [flag, value]
    end.sort
  end

  def check(path)
    plan = JSON.parse(File.binread(path))
    validate(plan)
    internal, external = interfaces(plan)
    expected = rules(plan, internal: internal, external: external)
    actual = command('iptables-save')
    raise 'Gateway firewall drift; run empeira up' unless normalized(actual) == normalized(expected)
    raise 'Gateway routing disabled; run empeira up' unless File.read('/proc/sys/net/ipv4/ip_forward').strip == '1'
  end

  def run(arguments)
    case arguments.first
    when 'hold' then sleep
    when 'lockdown'
      restore(lockdown)
    when 'apply' then apply(arguments.fetch(1))
    when 'route' then route(arguments.fetch(1))
    when 'block', 'unblock' then phase(*arguments)
    when 'check'
      check(arguments.fetch(1))
    else raise 'Unknown gateway operation'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    EmpeiraGateway.run(ARGV)
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
