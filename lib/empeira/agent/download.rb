# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'digest'
require 'timeout'

module Empeira
  module Agent
    # Host HTTPS transport. No redirects, shell commands, response-body diagnostics or persistent credentials.
    class Download
      def initialize(authentication:)
        @authentication = authentication
      end

      def fetch(url, path, sha256: nil)
        @authentication.attempt do
          File.open(path, 'wb', 0o600) do |file|
            request(url) do |response|
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

      def request(url)
        uri = URI(url)
        Configuration::AgentSchema.https_url!(url, 'agent artifact URL')
        request = http_request(uri)
        Timeout.timeout(180) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
                                              open_timeout: 10, read_timeout: 30, write_timeout: 30) do |http|
            http.request(request) do |response|
              yield validate_response!(response)
            end
          end
        end
      rescue OpenSSL::SSL::SSLError
        raise Error, 'Agent HTTPS certificate verification failed', cause: nil
      rescue IOError, SystemCallError, Timeout::Error, Net::ProtocolError, ArgumentError
        raise Error, 'Agent HTTPS download failed or timed out; check host network access', cause: nil
      end

      def http_request(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request['Accept-Encoding'] = 'identity'
        credentials = @authentication.credentials(uri.to_s)
        request.basic_auth(*credentials) if credentials
        request
      end

      def validate_response!(response)
        case response.code
        when '200' then response
        when '401' then raise AuthenticationRequired, 'Agent repository requires authentication'
        when '403' then raise Error, 'Agent repository access denied (HTTP 403)'
        when '407' then raise Error, 'Host proxy authentication failed (HTTP 407); repository login was not attempted'
        when '404' then raise Error, 'Agent artifact is unavailable (HTTP 404)'
        else raise Error, "Agent HTTPS request failed (HTTP #{response.code}); redirects are not followed"
        end
      end
    end
  end
end
