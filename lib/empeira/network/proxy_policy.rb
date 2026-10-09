# frozen_string_literal: true

module Empeira
  module Network
    class ProxyPolicy
      LABEL = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
      DOMAIN = /\A(?:\*\.)?#{LABEL}(?:\.#{LABEL})+\z/
      # Destination IP restrictions apply only to the authenticated bootstrap proxy.
      IPV4_FORBIDDEN = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
                          172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4].freeze
      # Squid normalizes mapped addresses to IPv4 before interpreting the prefix.
      # IPv6-sized prefixes are misparsed as ::/0, so retain the equivalent IPv4 prefix.
      MAPPED_FORBIDDEN = IPV4_FORBIDDEN.map { |range| "::ffff:#{range}" }.freeze
      FORBIDDEN = [*IPV4_FORBIDDEN, *MAPPED_FORBIDDEN, '::/128', '::1/128', 'fc00::/7', 'fe80::/10'].join(' ').freeze

      def self.valid_domain?(value)
        value.is_a?(String) && value.size <= 253 && value.match?(DOMAIN) &&
          !value.delete_prefix('*.').match?(/\A[\d.]+\z/) &&
          !value.end_with?('.empeira.internal', '.localhost') && value != 'empeira.internal'
      end

      def initialize(config, authorization: nil)
        @config = config
        @authorization = authorization
      end

      def configuration
        [
          'dns_nameservers @EMPEIRA_DNS@', 'http_port 3128',
          'visible_hostname empeira-proxy', 'cache deny all',
          'access_log none', 'cache_log /dev/null', 'pid_filename none',
          client_rule, 'http_access deny !clients',
          'request_header_access Proxy-Authorization deny all',
          'acl SSL_ports port 443', 'acl Safe_ports port 80 443', 'acl CONNECT method CONNECT',
          ("acl forbidden dst #{FORBIDDEN}" if @authorization), 'http_access deny !Safe_ports',
          'http_access deny CONNECT !SSL_ports', ('http_access deny forbidden' if @authorization),
          *destination_rules, 'http_access deny all', ''
        ].compact.join("\n")
      end

      def self.domain_rules(domains, name: 'permitted', condition: nil)
        return [] if domains.empty?

        destinations = domains.map { |domain| domain.start_with?('*.') ? ".#{domain.delete_prefix('*.')}" : domain }
        ["acl #{name} dstdomain -n #{destinations.join(' ')}",
         "http_access allow #{[condition, name].compact.join(' ')}"]
      end

      private

      def destination_rules
        return self.class.domain_rules(@config.fetch('global')) if @authorization

        ['include /empeira-proxy/proxy-rules.conf']
      end

      def client_rule
        return 'acl clients src "/empeira-proxy/proxy-clients"' unless @authorization

        "acl clients req_header Proxy-Authorization ^Basic[[:space:]]#{Regexp.escape(@authorization)}$"
      end
    end
  end
end
