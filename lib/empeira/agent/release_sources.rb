# frozen_string_literal: true

module Empeira
  module Agent
    # Apply the selected-source policy to native source files supplied by a release package.
    module ReleaseSources
      DNF_SCOPED_OPTIONS = %w[gpgcheck sslverify skip_if_unavailable includepkgs username password
                              mirrorlist metalink].freeze

      module_function

      def apt(content, format:, source:)
        urls = content.scan(%r{[a-z][a-z0-9+.-]*://[^\s]+}i)
        raise Error, 'Agent release package must provide HTTPS APT sources' if urls.empty?

        urls.each { |url| Configuration::AgentSchema.https_url!(url, 'agent release source URL') }
        trusted = source['verify_signatures'] == false
        format == '.sources' ? policy_deb822(content, trusted) : policy_list(content, trusted)
      end

      def policy_deb822(content, trusted)
        content.split(/\n\s*\n/).map do |stanza|
          safe = stanza.gsub(/^(?:Trusted|Allow-Insecure|Allow-Weak|Allow-Downgrade-To-Insecure):.*\n?/i, '').rstrip
          "#{safe}\n#{"Trusted: yes\n" if trusted}"
        end.join("\n")
      end

      def policy_list(content, trusted)
        content.gsub(/^(\s*deb(?:-src)?\s+)(?:\[([^\]]*)\]\s+)?/) do
          prefix = Regexp.last_match(1)
          options = Regexp.last_match(2).to_s.gsub(/\b(?:trusted|allow-[a-z-]+)=\S+/, '').strip
          options = [options, ('trusted=yes' if trusted)].compact.reject(&:empty?).join(' ')
          "#{prefix}#{"[#{options}] " unless options.empty?}"
        end
      end

      def dnf(content, target:, source:, package:)
        sections = content.split(/(?=^\[)/)
        sections.map do |section|
          section.start_with?('[') ? dnf_section(section, target, source, package) : section
        end.join
      end

      def scoped_dnf(section, source)
        section = section.gsub(/^\s*(?:#{DNF_SCOPED_OPTIONS.join('|')})\s*=.*\n?/, '')
        if source['verify_signatures'] == false
          section = section.gsub(/^\s*repo_gpgcheck\s*=.*\n?/, '')
          section = "#{section.rstrip}\nrepo_gpgcheck=0\n"
        end
        section
      end

      def dnf_section(section, target, source, package)
        urls = section.scan(/^\s*baseurl\s*=\s*(.+)$/).flatten.flat_map(&:split)
        raise Error, 'Agent release package must provide explicit HTTPS DNF base URLs' if urls.empty?

        urls.each { |url| Configuration::AgentSchema.https_url!(target.expand(url), 'agent release source URL') }
        section = scoped_dnf(section, source)
        "#{section.rstrip}\ngpgcheck=#{source['verify_signatures'] == false ? 0 : 1}\n" \
          "sslverify=1\nskip_if_unavailable=0\nincludepkgs=#{package}\n"
      end
    end
  end
end
