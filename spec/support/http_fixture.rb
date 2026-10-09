# frozen_string_literal: true

require 'socket'
require 'openssl'

# Owned synthetic HTTPS endpoint; normal transport verification stays enabled.
class HTTPFixture
  attr_reader :certificate, :requests, :port

  def initialize(address: '127.0.0.1', addresses: [], &handler)
    @handler = handler
    @requests = []
    key = OpenSSL::PKey::RSA.new(2048)
    @certificate = build_certificate(key, addresses)
    context = OpenSSL::SSL::SSLContext.new
    context.cert = @certificate
    context.key = key
    @socket = TCPServer.new(address, 0)
    @port = @socket.addr[1]
    @server = OpenSSL::SSL::SSLServer.new(@socket, context)
    @thread = Thread.new { serve }
  end

  def url(path = '/')
    "https://127.0.0.1:#{port}#{path}"
  end

  def close
    @thread.kill.join
    @socket.close
  end

  private

  # rubocop:disable-next Metrics/AbcSize -- Assemble one short-lived synthetic certificate with matching IP SANs.
  def build_certificate(key, addresses)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=Empeira synthetic HTTPS fixture')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    certificate_extensions(cert, addresses)
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  def certificate_extensions(cert, addresses)
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = factory.issuer_certificate = cert
    cert.add_extension(factory.create_extension('basicConstraints', 'CA:TRUE', true))
    names = ['127.0.0.1', *addresses].uniq.map { |ip| "IP:#{ip}" } + ['DNS:localhost']
    cert.add_extension(factory.create_extension('subjectAltName', names.join(',')))
  end

  def serve
    loop do
      client = @server.accept
      begin
        handle(client)
      ensure
        client.close
      end
    rescue OpenSSL::SSL::SSLError
      # An untrusted-certificate test deliberately aborts the TLS handshake.
      next
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Parse one minimal request and emit its actual response plus Basic challenge.
  def handle(client)
    request = client.gets&.strip
    return unless request

    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.downcase] = value.strip
    end
    @requests << [request, headers]
    code, reason, body, type = @handler.call(request, headers)
    challenge = code == '401' ? "WWW-Authenticate: Basic realm=\"synthetic\"\r\n" : ''
    client.write("HTTP/1.1 #{code} #{reason}\r\nContent-Length: #{body.bytesize}\r\n" \
                 "#{challenge}Content-Type: #{type || 'text/plain'}\r\nConnection: close\r\n\r\n#{body}")
  end
end
