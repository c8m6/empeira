# frozen_string_literal: true

module Empeira
  module Server
    module HTTP
      def self.arguments
        ['curl', '--silent', '--show-error', '--fail-with-body', '--max-time', '8', '--noproxy', '*']
      end

      def self.tls_arguments
        ssl = '/etc/puppetlabs/puppet/ssl'
        [*arguments, '--cacert', "#{ssl}/certs/ca.pem", '--cert', "#{ssl}/certs/server.empeira.internal.pem",
         '--key', "#{ssl}/private_keys/server.empeira.internal.pem"]
      end

      def self.response(result)
        text = result.stdout
        status = reason = type = nil
        while (match = %r{\AHTTP/\S+ (\d{3})(?: ([^\r\n]*))?\r?\n((?:[^\r\n]+\r?\n)*)\r?\n}.match(text))
          status = match[1]
          reason = match[2]
          type = match[3][/^Content-Type:\s*([^\r\n]+)/i, 1]
          text = text[match[0].length..]
        end
        { status: status, reason: reason, body: text, content_type: type }
      end

      def self.failure(result, url:, operation:)
        data = response(result)
        return Execution::Diagnostics.native(result, operation: operation, tool: 'curl', url: url) unless data[:status]

        detail = Execution::Diagnostics.http(operation: operation, url: url, **data)
        stderr = Execution::Diagnostics.bounded(Execution::Diagnostics.safe_text(result.stderr))
        "#{detail}\n#{stderr}"
      end
    end
  end
end
