# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'digest'
require 'timeout'

module Empeira
  module Agent
    # Host HTTPS transport with bounded diagnostics and acquisition-scoped authentication.
    class Download
      HTTP_OPTIONS = { use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
                       open_timeout: 10, read_timeout: 30, write_timeout: 30 }.freeze
      FAILURE_HINTS = { '403' => 'access denied', '407' => 'Host proxy authentication failed',
                        '404' => 'artifact unavailable' }.freeze
      def initialize(authentication:)
        @authentication = authentication
      end

      def fetch(url, path, sha256: nil, operation: 'Download agent package')
        @authentication.attempt do
          File.open(path, 'wb', 0o600) do |file|
            request(url, operation) do |response|
              write_response(file, response)
            end
            file.flush
            file.fsync
          end
        end
        raise Error, 'Agent artifact download is empty' if File.empty?(path)
        raise Error, 'Agent artifact checksum mismatch' if sha256 && Digest::SHA256.file(path).hexdigest != sha256
      rescue StandardError, Interrupt
        FileUtils.rm_f(path)
        raise
      end

      private

      def write_response(file, response)
        response.read_body { |part| file.write(part) }
        length = response['Content-Length']
        raise Error, 'Agent artifact download is incomplete' if length && file.size != Integer(length)
      end

      def request(url, operation)
        received = nil
        uri = URI(url)
        Configuration::AgentSchema.https_url!(url, 'agent artifact URL')
        Timeout.timeout(180) do
          Net::HTTP.start(uri.host, uri.port, **HTTP_OPTIONS) do |http|
            http.request(http_request(uri)) do |response|
              received = response
              yield validate_response!(response, url, operation)
            end
          end
        end
      rescue SocketError, OpenSSL::SSL::SSLError, IOError, SystemCallError, Timeout::Error, Net::ProtocolError => e
        detail = Execution::Diagnostics.transport(operation: operation, url: url, error: e,
                                                  response: received, secrets: @authentication.credentials || [])
        raise Error, "Agent HTTPS download failed\n#{detail}", cause: nil
      end

      def http_request(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request['Accept-Encoding'] = 'identity'
        credentials = @authentication.credentials(uri.to_s)
        request.basic_auth(*credentials) if credentials
        request
      end

      def validate_response!(response, url, operation)
        return response if response.code == '200'

        detail = Execution::Diagnostics.http_response(response, operation: operation, url: url,
                                                                secrets: @authentication.credentials || [])
        raise AuthenticationRequired.new(detail, url: url) if response.code == '401'

        fallback = response.code.start_with?('3') ? 'redirects are not followed' : 'HTTP error response'
        hint = FAILURE_HINTS.fetch(response.code, fallback)
        raise Error, "Agent HTTPS request failed: #{hint}\n#{detail}", cause: nil
      end
    end
  end
end
