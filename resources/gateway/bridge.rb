#!/usr/bin/env ruby
# frozen_string_literal: true

load File.join(__dir__, 'empeira-gateway') unless defined?(EmpeiraGateway)

# Docker's internal bridge filtering otherwise discards off-subnet IP packets
# even when their Ethernet destination is another peer (the workspace gateway).
# This helper changes only two owned bridge rules, never engine chains/policies.
module EmpeiraBridge
  module_function

  def backend
    candidates = %w[iptables iptables-legacy].select do |binary|
      _output, _error, status = Open3.capture3(binary, '-t', 'filter', '-S', 'DOCKER-USER')
      status.success?
    rescue Errno::ENOENT
      false
    end
    raise 'Cannot identify Docker iptables backend; workspace remains isolated' if candidates.empty?

    candidates.last
  end

  def rules(bridge, subnet, identity)
    comment = ['-m', 'comment', '--comment', "empeira:#{identity}", '-j', 'ACCEPT']
    [['raw', 'PREROUTING', ['-i', bridge, '-s', subnet, *comment]],
     ['filter', 'FORWARD', ['-i', bridge, '-o', bridge, *comment]]]
  end

  def validate(action, bridge, subnet, identity)
    raise 'Invalid workspace bridge operation' unless %w[apply remove check].include?(action)
    unless bridge.match?(/\Aep[a-f0-9]{10}\z/) && identity.match?(/\A[a-f0-9]{64}\z/)
      raise 'Invalid workspace bridge identity'
    end
    raise 'Invalid workspace subnet' unless IPAddr.new(subnet).ipv4? && IPAddr.new(subnet).prefix == 24
    raise 'Workspace bridge is unavailable' unless File.directory?("/sys/class/net/#{bridge}/bridge")
  end

  def run(action, bridge, subnet, identity)
    validate(action, bridge, subnet, identity)
    binary = backend
    rules(bridge, subnet, identity).each do |table, chain, arguments|
      reconcile(binary, action, table, chain, arguments)
    end
  end

  def reconcile(binary, action, table, chain, arguments)
    _output, _error, status = Open3.capture3(binary, '--wait', '5', '-t', table, '-C', chain, *arguments)
    raise 'Workspace bridge attachment rules missing; run empeira up' if action == 'check' && !status.success?

    if action == 'apply' && !status.success?
      EmpeiraGateway.command(binary, '--wait', '5', '-t', table, '-I', chain, '1', *arguments)
    elsif action == 'remove' && status.success?
      EmpeiraGateway.command(binary, '--wait', '5', '-t', table, '-D', chain, *arguments)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    EmpeiraBridge.run(*ARGV)
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
