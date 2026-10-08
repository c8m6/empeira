# frozen_string_literal: true

require 'socket'

# Restart leaves an already running endpoint alone. Each guest owns this fixture process.
begin
  tcp = TCPServer.new('0.0.0.0', 24_681)
rescue Errno::EADDRINUSE
  exit 0
end
udp = UDPSocket.new
udp.bind('0.0.0.0', 24_682)
http = TCPServer.new('0.0.0.0', 24_683)
Process.daemon
Thread.new do
  loop do
    client = tcp.accept
    client.write(client.read(4))
    client.close
  end
end
Thread.new do
  loop do
    client = http.accept
    loop { break if client.gets == "\r\n" }
    client.write("HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\npeer-http")
    client.close
  end
end
loop do
  data, address = udp.recvfrom(1024)
  udp.send(data, 0, address[3], address[1])
end
