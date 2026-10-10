# frozen_string_literal: true

module Empeira
  module VM
    class InterfaceRoutes
      def self.validate_static!(desired, hostname:, config:, subnet:)
        protected = [subnet].compact + config.dig('network', 'redirects').map do |entry|
          entry.fetch('from').fetch('ip')
        end
        desired.each do |name, definition|
          protected.each { |range| reject_overlap!(definition.fetch('network'), range, hostname, name) }
        end
      end

      def self.reject_overlap!(network, range, hostname, name)
        return unless Configuration::VMInterfaces.overlap?(IPAddr.new(network), IPAddr.new(range))

        raise ConfigurationError, "Host #{hostname}, interface #{name}, vm.interfaces: network #{network} " \
                                  "conflicts with protected route/address #{range} (including network.redirects)"
      end

      def initialize(guest:, ownership:, hostname:)
        @guest = guest
        @ownership = ownership
        @hostname = hostname
      end

      def validate!(desired)
        protected = foreign_addresses + foreign_routes
        desired.each do |name, definition|
          protected.each { |range| self.class.reject_overlap!(definition.fetch('network'), range, @hostname, name) }
        end
      rescue IPAddr::InvalidAddressError, KeyError, TypeError
        raise Error, "Host #{@hostname}, vm.interfaces: guest routes/addresses cannot be verified", cause: nil
      end

      def foreign_addresses
        @guest.addresses.flat_map do |name, addresses|
          next [] unless @ownership.accepted(name).empty?

          addresses.filter_map do |address|
            "#{address.fetch('local')}/#{address.fetch('prefixlen')}" if address['family'] == 'inet'
          end
        end
      end

      def foreign_routes
        @guest.routes.filter_map do |route|
          raise Error, "Host #{@hostname}, vm.interfaces: route destination is missing" if route['dst'].nil?
          raise Error, "Host #{@hostname}, vm.interfaces: unresolved route nexthop ID" if route.key?('nhid')
          next if foreign_default?(route)
          next if automatic_owned_route?(route)

          owned = owned_route_device(route)
          @ownership.conflict!(owned, 'interface carries a non-generated route; mutation refused') if owned

          route.fetch('dst')
        end
      end

      def foreign_default?(route)
        %w[default 0.0.0.0/0].include?(route['dst']) && owned_route_device(route).nil?
      end

      def owned_route_device(route)
        hops = route.values_at('multipath', 'nexthops').compact.flatten
        devices = [route['dev'], *hops.map { |hop| hop.fetch('dev') }].compact
        devices.find { |name| !@ownership.accepted(name).empty? }
      end

      def automatic_owned_route?(route)
        return false unless ordinary_kernel_route?(route)

        @ownership.accepted(route['dev']).any? do |definition|
          next false unless definition['network']

          generated_route?(route, definition.fetch('network'))
        end
      end

      def ordinary_kernel_route?(route)
        route['protocol'] == 'kernel' && !route.key?('gateway') && !route.key?('multipath') &&
          !route.key?('nexthops') && [nil, 'main', 'local', 254, 255].include?(route['table'])
      end

      def generated_route?(route, network)
        subnet = IPAddr.new(network)
        target = IPAddr.new(route.fetch('dst'))
        case route['type']
        when 'local' then target.prefix == 32 && target.to_s == network.split('/').first
        when 'broadcast' then broadcast?(target, subnet)
        else route['scope'] == 'link' && target == subnet && target.prefix == subnet.prefix
        end
      end

      def broadcast?(target, subnet)
        target.prefix == 32 && [subnet.to_range.first.to_s, subnet.to_range.last.to_s].include?(target.to_s)
      end
    end
  end
end
