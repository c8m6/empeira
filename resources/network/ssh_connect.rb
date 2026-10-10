# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only
# SSH byte tunnel inside the rootless runtime namespace.
require 'socket'
require 'ipaddr'

address, value = ARGV.size == 1 ? ['127.0.0.1', ARGV.fetch(0)] : ARGV
ip = IPAddr.new(address)
raise ArgumentError, 'Invalid SSH destination' unless ip.ipv4? && (ip.private? || address == '127.0.0.1')

port = Integer(value, 10)
raise ArgumentError, 'Invalid management SSH port' unless port.between?(1, 65_535)

begin
  Socket.tcp(address, port, connect_timeout: 5) do |socket|
    request = Thread.new do
      IO.copy_stream($stdin, socket)
      socket.close_write
    rescue IOError, SystemCallError
      nil
    end
    begin
      IO.copy_stream(socket, $stdout)
    ensure
      request.kill.join
    end
  end
rescue IOError, SystemCallError
  exit 1
end
