# frozen_string_literal: true

require 'ipaddr'
require 'socket'

module Empeira
  module Network
    module DirectEgress
      DNS_LABEL = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
      DNS_NAME = /\A#{DNS_LABEL}(?:\.#{DNS_LABEL})*\z/
      MAX_HOSTS = 256

      Resolved = Data.define(:entries) do
        def fingerprint
          Infrastructure::Definition.fingerprint(entries)
        end

        def configuration
          JSON.generate('version' => 1, 'entries' => entries)
        end
      end

      module_function

      def validate!(value, path = 'network.egress')
        return legacy!(value, path) if value.is_a?(Hash)
        unless value.is_a?(Array) && value.size <= MAX_HOSTS
          raise ConfigurationError, "#{path} must be an array with at most #{MAX_HOSTS} destination entries"
        end

        hosts = value.each_with_index.map { |entry, index| validate_entry!(entry, "#{path}[#{index}]") }
        raise ConfigurationError, "#{path} contains duplicate destinations" unless hosts.uniq.size == hosts.size
      end

      def legacy!(value, path)
        return if value.keys == ['mode'] && %w[none proxy].include?(value['mode'])

        raise ConfigurationError, "#{path} must be a host array (legacy mode accepts only none or proxy)"
      end

      def destinations(value)
        return [] unless value.is_a?(Array)

        value.map { |entry| entry.fetch('host') { entry.fetch('ip') } }
      end

      def validate_entry!(entry, path)
        unless entry.is_a?(Hash) && [%w[host ports], %w[ip ports]].include?(entry.keys.sort)
          raise ConfigurationError, "#{path} must contain ports and exactly one of host or ip"
        end

        entry.key?('host') ? validate_host!(entry['host'], path) : validate_ip!(entry['ip'], path)
        validate_ports!(entry['ports'], path)
        entry.slice('host', 'ip')
      end

      def validate_host!(host, path)
        if host.is_a?(String) && host.size <= 253 && host.match?(DNS_NAME) &&
           host.include?('.') && !host.match?(/\A[\d.]+\z/)
          return
        end

        raise ConfigurationError, "#{path}.host must be a lowercase DNS hostname"
      end

      def validate_ip!(value, path)
        raise IPAddr::InvalidAddressError unless value.is_a?(String) && !value.include?('/')

        ip = IPAddr.new(value)
        raise ConfigurationError, "#{path}.ip: IPv6 is not supported; the workspace is IPv4-only" if ip.ipv6?
        return if ip.to_s == value

        raise ConfigurationError, "#{path}.ip must be an explicit IPv4 address"
      rescue IPAddr::InvalidAddressError
        raise ConfigurationError, "#{path}.ip must be an explicit IPv4 address", cause: nil
      end

      def validate_ports!(ports, path)
        valid = ports.is_a?(Array) && !ports.empty? && ports.uniq.size == ports.size &&
                ports.all? { |port| port.is_a?(Integer) && port.between?(1, 65_535) }
        return if valid

        raise ConfigurationError, "#{path}.ports must contain unique TCP ports from 1 through 65535"
      end

      class Resolver
        def initialize(lookup: nil, logger: nil)
          @lookup = lookup || method(:addresses)
          @logger = logger
        end

        def resolve(config)
          entries = config.is_a?(Array) ? config : []
          return Resolved.new([].freeze) if entries.empty?

          resolved = entries.map { |entry| resolve_entry(entry) }.sort_by { |entry| entry['host'] || entry['ip'] }
          Resolved.new(resolved.freeze)
        end

        private

        def resolve_entry(entry)
          host = entry['host']
          addresses = entry.key?('ip') ? [entry.fetch('ip')] : ipv4_addresses(host)
          raise Error, "Direct-egress host did not resolve to a supported IPv4 address: #{host}" if addresses.empty?

          ports = entry.fetch('ports').sort
          @logger&.call(operation: 'direct_egress_resolution', host: host, addresses: addresses, ports: ports)
          entry.slice('host', 'ip').merge('addresses' => addresses, 'ports' => ports).freeze
        rescue IPAddr::InvalidAddressError, SocketError
          raise Error, "Direct-egress host could not be resolved: #{host}", cause: nil
        end

        def ipv4_addresses(host)
          @lookup.call(host).map { |value| IPAddr.new(value) }.select(&:ipv4?).map(&:to_s).uniq.sort
        end

        def addresses(host)
          Socket.getaddrinfo(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM).map { |entry| entry[3] }
        end
      end
    end
  end
end
