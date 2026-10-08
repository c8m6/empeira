# frozen_string_literal: true

require 'socket'
require 'openssl'
require 'resolv'
require 'timeout'

# Two fixed listeners for one backend. The TLS endpoint satisfies the PuppetDB
# terminus; the isolated Empeira network is the security boundary.
BACKEND = 'puppetdb-backend.empeira.internal'
MAX_CONNECTIONS = 64
tokens = Queue.new
MAX_CONNECTIONS.times { tokens << true }
context = OpenSSL::SSL::SSLContext.new
context.cert = OpenSSL::X509::Certificate.new(File.read('/empeira-relay/cert.pem'))
context.key = OpenSSL::PKey.read(File.read('/empeira-relay/key.pem'))
context.verify_mode = OpenSSL::SSL::VERIFY_NONE
listeners = { TCPServer.new('0.0.0.0', 8080) => false, TCPServer.new('0.0.0.0', 8081) => true }

def backend_address
  Resolv::DNS.open(nameserver: [ENV.fetch('EMPEIRA_DNS_IP')], search: [], ndots: 1) do |dns|
    dns.timeouts = 2
    dns.getresource(BACKEND, Resolv::DNS::Resource::IN::A).address.to_s
  end
end

def respond(connection, status)
  connection.write("HTTP/1.1 #{status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
rescue IOError, SystemCallError
  nil
end

def pump(source, destination)
  loop { destination.write(source.readpartial(16_384)) }
rescue EOFError
  destination.close_write if destination.is_a?(TCPSocket)
end

# rubocop:disable-next Metrics/BlockLength -- Bounded bidirectional connection handling is kept together.
loop do
  IO.select(listeners.keys).first.each do |listener|
    socket = listener.accept
    begin
      tokens.pop(true)
    rescue ThreadError
      respond(socket, '503 Service Unavailable') unless listeners.fetch(listener)
      socket.close
      next
    end
    Thread.new(socket, listeners.fetch(listener)) do |client, tls|
      connection = nil
      upstream = nil
      sender = nil
      begin
        connection = tls ? OpenSSL::SSL::SSLSocket.new(client, context) : client
        Timeout.timeout(5) { connection.accept } if tls
        request = Timeout.timeout(10) { connection.gets("\n", 8192) }
        unless request&.match?(%r{\A(?:GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH) /\S* HTTP/1\.[01]\r?\n\z})
          respond(connection, '400 Bad Request')
          next
        end
        upstream = Socket.tcp(backend_address, 8080, connect_timeout: 5)
        upstream.write(request)
        Timeout.timeout(120) do
          sender = Thread.new { pump(connection, upstream) }
          pump(upstream, connection)
        end
      rescue Timeout::Error
        respond(connection, '504 Gateway Timeout') if connection && !upstream
      rescue IOError, SystemCallError, Resolv::ResolvError, SocketError, OpenSSL::SSL::SSLError
        respond(connection, '502 Bad Gateway') if connection && !upstream
      ensure
        sender&.kill&.join
        upstream&.close
        connection&.close
        client.close unless client.closed?
        tokens << true
      end
    end
  end
end
