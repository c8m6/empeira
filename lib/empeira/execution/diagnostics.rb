# frozen_string_literal: true

module Empeira
  module Execution
    # Tool output is untrusted. Publish only bounded diagnostic lines, never commands or response bodies.
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
