# frozen_string_literal: true

require 'uri'
require 'base64'

module Empeira
  module Execution
    # Bounded, sanitized diagnostics for direct HTTP responses and native tool failures.
    # rubocop:disable-next Metrics/ModuleLength -- HTTP, native tools and SSH share the existing redaction boundary.
    module Diagnostics
      RELEVANT = %r{permission\sdenied|could\snot|couldn't|cannot\s|unable\sto|failed|failure|fatal:|error:|not\sfound|
                    does\snot\sexist|not\sa\svalid|not\sappear|connection|timed?\sout|resolve|name\sor\sservice|
                    server\sresponded|HTTP[\s/]|certificate|host\skey|load\skey|invalid|conflicts|
                    unauthorized|forbidden|authentication\srequired|denied|insufficient_scope|manifest\sunknown|
                    name\sunknown|x509|unknown\sauthority|network\sunreachable|DNS\sfailure|timeout|
                    no\sbasic\sauth\scredentials|toomanyrequests|rate[\s-]limit|too\smany\srequests|
                    \A(?:Get|Head|Post)\s|
                    Puppetfile\smoduledir|\AModule\s[a-z][a-z0-9_]*[:\s]}ix
      SECRET = /[a-z0-9_-]*(?:authorization|token|password|passwd|secret|api[-_]?key|access[-_]?key|credential|cookie)
                [a-z0-9_-]*/ix
      LIMIT = 8192
      URL = %r{\b(?:https?|ssh|docker|oci)://[^\s<>"']+}
      QUERY_SECRET = /#{SECRET}|auth|(?:\A|[-_])(?:sig|signature|key|session|jwt)\z/i

      # rubocop:disable-next Metrics/ParameterLists -- Keep actual response fields explicit at the diagnostic boundary.
      def self.http(operation:, url:, status:, reason:, body: nil, content_type: nil, secrets: [])
        values = secrets + url_secrets(url)
        response = body.nil? ? '[No response body available]' : response_text(body, content_type, values)
        "Operation: #{safe_text(operation, secrets: values)}\nURL: #{safe_url(url)}\n" \
          "HTTP status: #{safe_text("#{status} #{reason}", secrets: values).strip}\nResponse:\n" \
          "#{response.lines.map { |line| "  #{line}" }.join}"
      end

      def self.http_response(response, operation:, url:, secrets: [])
        http(operation: operation, url: url, status: response.code, reason: response.message,
             body: read_body(response), content_type: response['Content-Type'], secrets: secrets)
      end

      def self.read_body(response)
        body = +''.b
        response.read_body do |chunk|
          body << chunk
          break if body.bytesize > LIMIT * 8
        end
        body
      rescue IOError, SystemCallError, Timeout::Error, Net::ProtocolError => e
        "#{body}\n[Response body incomplete: #{e.class.name}]"
      end

      def self.transport(operation:, url:, error:, response: nil, secrets: [])
        response ||= error.response if error.respond_to?(:response) && error.response.respond_to?(:code)
        status = response ? "#{response.code} #{response.message}" : 'No HTTP response received'
        "Operation: #{safe_text(operation)}\nURL: #{safe_url(url)}\nConnection: #{connection(error)}\n" \
          "HTTP status: #{safe_text(status)}\nDetails: " \
          "#{bounded(safe_text(error.message, secrets: secrets + url_secrets(url)))}"
      end

      def self.connection(error)
        case error
        when OpenSSL::SSL::SSLError then 'TLS connection or certificate verification failed'
        when SocketError then 'DNS resolution failed'
        when Errno::ECONNREFUSED then 'Connection refused'
        when Timeout::Error, Errno::ETIMEDOUT then 'Connection timed out'
        when Net::HTTPFatalError then 'Proxy connection failed'
        else 'Connection or transfer failed'
        end
      end

      def self.native(result, operation:, tool:, url: nil, secrets: [])
        text = safe_text("#{result.stderr}\n#{result.stdout}", secrets: secrets)
        location = url ? safe_url(url) : "Not reported separately by #{tool}; see native output"
        "Operation: #{safe_text(operation)}\nURL: #{location}\n" \
          "HTTP status / reason: Not reported separately by #{tool}; see native output\n" \
          "Response: Not provided separately by #{tool}\n" \
          "#{tool} output (exit=#{result.exit_status}, timeout=#{result.timed_out}):\n" \
          "#{text.strip.empty? ? '[No native diagnostic available]' : bounded(text.strip)}"
      end

      def self.command(result, operation:, tool:, secrets: [])
        secrets += %w[EMPEIRA_AGENT_REPO_USERNAME EMPEIRA_AGENT_REPO_PASSWORD].filter_map { |key| ENV.fetch(key, nil) }
        stdout = bounded(safe_text(result.stdout, secrets: secrets))
        stderr = bounded(safe_text(result.stderr, secrets: secrets))
        "Operation: #{safe_text(operation, secrets: secrets)}\nTool: #{safe_text(tool)}\n" \
          "Exit code: #{result.exit_status || 'unavailable'}\nTimeout: #{result.timed_out}\n" \
          "stdout:\n#{stdout.empty? ? '[Empty]' : stdout}\nstderr:\n#{stderr.empty? ? '[Empty]' : stderr}"
      end

      def self.response_text(body, content_type, secrets)
        return '[Empty response body]' if body.empty?
        return '[Binary response body omitted]' if binary?(body, content_type)

        text = safe_text(body, secrets: secrets)
        prefix = content_type.to_s.match?(/html/i) ? "[HTML response]\n" : ''
        "#{prefix}#{bounded(text)}"
      end

      def self.binary?(body, content_type)
        body.b.match?(/[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f]/n) ||
          content_type.to_s.match?(%r{\A(?:application/octet-stream|image/|audio/|video/)}) ||
          (!body.dup.force_encoding('UTF-8').valid_encoding? && !content_type.to_s.match?(/text|json|xml/i))
      end

      def self.bounded(text)
        return text if text.bytesize <= LIMIT

        "#{text.byteslice(0, LIMIT).scrub}\n[Truncated diagnostic after #{LIMIT} bytes]"
      end

      def self.safe_url(value)
        uri = URI(value.to_s)
        uri.user = nil
        uri.password = nil
        uri.fragment = nil
        if uri.query
          uri.query = URI.encode_www_form(URI.decode_www_form(uri.query).map do |key, item|
            [key, key.match?(QUERY_SECRET) ? '[REDACTED]' : item]
          end)
        end
        uri.to_s
      rescue URI::InvalidURIError, ArgumentError
        '[Invalid URL omitted]'
      end

      def self.url_secrets(value)
        uri = URI(value.to_s)
        fields = uri.userinfo.to_s.split(':', 2) + URI.decode_www_form(uri.query.to_s).filter_map do |key, item|
          item if key.match?(QUERY_SECRET)
        end
        fields.flat_map { |field| [field, URI.decode_www_form_component(field)] }.reject(&:empty?)
      rescue URI::InvalidURIError, ArgumentError
        []
      end

      # Redact before limiting output; retain actual URL hosts/paths and multiline server details.
      def self.safe_text(text, secrets: [])
        value = text.to_s.dup.force_encoding('UTF-8').scrub
        values = known_values(value, secrets)
        value = value.gsub(URL) { |url| safe_url(url) }
        values.each { |item| value = value.gsub(item, '[REDACTED]') }
        strip_controls(redact_fields(value))
      end

      def self.known_values(text, secrets)
        values = secrets + text.scan(URL).flat_map { |url| url_secrets(url) }
        values << Base64.strict_encode64(secrets.join(':')) if secrets.size == 2
        values.reject(&:empty?).uniq.sort_by { |item| -item.length }
      end

      def self.redact_fields(value)
        value = value.gsub(/-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\z)/m, '[REDACTED]')
        value = value.gsub(/^\s*(?:\S*-)?(?:Authorization|Cookie|Set-Cookie):[^\n]*/i, '[REDACTED HEADER]')
        value = value.gsub(/\bno basic auth credentials\b/i, 'authentication required (no credentials)')
        value = value.gsub(/\b(?:Bearer|Basic)\s+\S+/i, '[REDACTED]')
        value = value.gsub(/((?:#{SECRET})["']?\s*[=:]\s*)(?:"[^"]*"|'[^']*'|\S+)/i, '\1[REDACTED]')
        value.gsub(/\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+)/, '[REDACTED]')
      end

      def self.strip_controls(value)
        value.gsub(/\e\][^\a]*(?:\a|\e\\)/, '').gsub(/\e\[[0-9;]*[A-Za-z]/, '')
             .gsub(/[\p{Cc}\p{Cf}&&[^\n\t]]/, '')
      end

      def self.registry_failure(diagnostic, timed_out: false)
        return :network if timed_out || diagnostic.match?(/timed?\s*out|timeout/i)
        return :tls if diagnostic.match?(/x509|certificate.*(?:failed|unknown|expired)|unknown authority/i)
        if diagnostic.match?(/connection\srefused|network\s(?:is\s)?unreachable|no\ssuch\shost|DNS\sfailure|
                              (?:name|temporary)\sresolution|could\snot\sresolve\s(?:host|hostname)/ix)
          return :network
        end

        auth = diagnostic.gsub(/permission denied/i, '')
        if auth.match?(/\b(?:401|403|unauthorized|forbidden|denied|insufficient_scope)\b|
                       authentication\srequired|no\sbasic\sauth\scredentials/ix)
          return :auth
        end
        return :missing if diagnostic.match?(/manifest unknown|name unknown|not found/i)

        :unknown
      end

      def self.clean(text)
        value = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
        value = value.gsub(/-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\z)/m, '[REDACTED]')
        value.lines.filter_map { |line| diagnostic(line) }.first(20).join("\n")
      end

      def self.diagnostic(line)
        line = line.gsub(/\e\][^\a]*(?:\a|\e\\)/, '').gsub(/\e\[[0-9;]*[A-Za-z]/, '')
                   .gsub(/[\p{Cc}\p{Cf}]/, ' ').strip
        return if line.empty? || !line.match?(RELEVANT) || line.match?(/authorization|cookie/i)
        if line.match?(/(?:executing|command|running):|\b(?:git|ssh)\s+(?:-\S+\s+)*(?:clone|fetch|checkout|ls-remote)/i)
          return
        end

        sanitize(line)[0, 500]
      end

      def self.sanitize(line)
        line = line.gsub(/\bno basic auth credentials\b/i, 'authentication required (no credentials)')
        line = line.gsub(%r{\b(?:https?|ssh|docker|oci)://[^\s<>"']+}, '[REDACTED URL]')
        line = line.gsub(/\b(?:Bearer|Basic)\s+\S+/i, '[REDACTED]')
        line = line.gsub(/((?:#{SECRET})["']?\s*[=:]\s*)(?:"[^"]*"|'[^']*'|\S+)/i, '\1[REDACTED]')
        line = line.gsub(/\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+)/, '[REDACTED]')
        line = line.gsub(/((?:load key|identity file|private key)\s*)["'][^"']*["']/i, '\1[REDACTED PATH]')
        line = line.gsub(%r{"/[^"\n]*"|'/[^'\n]*'}, '[REDACTED PATH]')
        line.gsub(%r{(?<![\w/])(?:~?/)[^\s"'<>:]+}, '[REDACTED PATH]')
      end
    end
  end
end
