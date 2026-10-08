# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only
# Management SSH byte tunnel inside the rootless runtime namespace.
require 'socket'

port = Integer(ARGV.fetch(0), 10)
raise ArgumentError, 'Invalid management SSH port' unless port.between?(1, 65_535)

begin
  Socket.tcp('127.0.0.1', port, connect_timeout: 5) do |socket|
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
