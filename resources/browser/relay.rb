# frozen_string_literal: true

require 'socket'

# Fixed destination, opaque TLS bytes: no HTTP proxy, CONNECT or routing interface.
listener = TCPServer.new('0.0.0.0', 3001)
loop do
  client = listener.accept
  Thread.new(client) do |connection|
    address = File.read('/empeira-browser/address').strip
    Socket.tcp(address, 3001, connect_timeout: 5) do |upstream|
      sender = Thread.new { IO.copy_stream(connection, upstream) }
      IO.copy_stream(upstream, connection)
    ensure
      sender&.kill&.join
    end
  rescue IOError, SystemCallError, SocketError
    nil
  ensure
    connection.close
  end
end
