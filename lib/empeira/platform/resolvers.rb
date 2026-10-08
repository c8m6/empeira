# frozen_string_literal: true

module Empeira
  module Platform
    class Resolvers
      attr_reader :routes

      def initialize(platform:, runner:, reader: File)
        @platform = platform
        @runner = runner
        @reader = reader
        @routes = {}
      end

      def resolve(config)
        return usable(config.fetch('servers')) if config.fetch('mode') == 'explicit'

        usable(@platform.os == :macos ? macos : linux)
      end

      private

      def linux
        addresses = read('/etc/resolv.conf').scan(/^nameserver\s+(\S+)/).flatten
        return addresses if addresses.any? { |address| reachable?(address) }

        read('/run/systemd/resolve/resolv.conf').scan(/^nameserver\s+(\S+)/).flatten
      end

      def macos
        result = @runner.run('scutil', arguments: ['--dns'], timeout: 10)
        unless result.success?
          raise Error,
                'Cannot discover macOS DNS; configure dns.upstream.mode=explicit and servers'
        end

        parse_macos(result.stdout)
      end

      def parse_macos(output)
        defaults = []
        output.split(/^resolver #/).each do |block|
          next if block.match?(/options\s*:\s*mdns/)

          addresses = macos_addresses(block)
          domain = block[/^\s*domain\s*:\s*([a-zA-Z0-9.-]+)\s*$/, 1]&.downcase
          defaults = route_or_default(domain, addresses, defaults)
        end
        defaults
      end

      def route_or_default(domain, addresses, defaults)
        return defaults if domain&.end_with?('empeira.internal')
        return defaults.empty? ? addresses : defaults unless domain

        @routes[domain] = addresses unless addresses.empty?
        defaults
      end

      def macos_addresses(block)
        block.scan(/nameserver\[\d+\]\s*:\s*(\S+)/).flatten.select { |ip| reachable?(ip) }
      end

      def read(path)
        @reader.read(path)
      rescue SystemCallError
        ''
      end

      def reachable?(address)
        ip = IPAddr.new(address)
        !ip.loopback? && !ip.link_local? && ip.to_i.positive?
      rescue IPAddr::InvalidAddressError
        false
      end

      def usable(addresses)
        result = addresses.select { |address| reachable?(address) }.uniq
        return result unless result.empty?

        raise Error, 'No container-reachable DNS upstream found; configure dns.upstream.mode=explicit and servers'
      end
    end
  end
end
