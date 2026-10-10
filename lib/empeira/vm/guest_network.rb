# frozen_string_literal: true

require 'json'

module Empeira
  module VM
    # All observations and mutations use the existing guest management transport.
    class GuestNetwork
      attr_reader :links, :addresses, :routes

      def initialize(guest:, record:)
        @guest = guest
        @record = record
      end

      def refresh
        @links = read(%w[ip -j -d link show]).to_h { |link| [link.fetch('ifname'), link] }
        @addresses = read(%w[ip -j address show]).to_h { |link| [link.fetch('ifname'), link.fetch('addr_info')] }
        @routes = read(%w[ip -j -4 route show table all])
        self
      rescue KeyError, TypeError
        raise Error, "Host #{@record.fetch('hostname')}, vm.interfaces: incomplete guest network observation",
              cause: nil
      end

      def load_modules(vlan:)
        # Prevent module autoload from creating an unowned default dummy0.
        command(%w[modprobe dummy numdummies=0]) unless @guest.run(@record, %w[test -d /sys/module/dummy]).success?
        command(%w[modprobe 8021q]) if vlan && !@guest.run(@record, %w[test -d /sys/module/8021q]).success?
      end

      def command(arguments)
        result = @guest.run(@record, arguments)
        return result if result.success?

        details = Execution::Diagnostics.command(result, operation: operation(arguments), tool: arguments.first)
        raise Error, "Cannot reconcile VM interfaces; guest operation failed\n#{details}", cause: nil
      rescue Guest::TransportError => e
        raise e.with_context(operation(arguments)), cause: nil
      end

      def operation(arguments)
        position = arguments.index('dev') || arguments.index('name')
        interface = position ? ", interface #{arguments[position + 1]}" : ''
        "Host #{@record.fetch('hostname')}#{interface}, vm.interfaces: #{arguments.first}"
      end

      def read(arguments)
        value = JSON.parse(command(arguments).stdout)
        return value if value.is_a?(Array) && value.all?(Hash)

        raise TypeError
      rescue JSON::ParserError, TypeError
        raise Error, "Host #{@record.fetch('hostname')}, vm.interfaces: cannot verify guest #{arguments.first} JSON",
              cause: nil
      end

      def ipv4(name)
        addresses.fetch(name, []).select { |address| address['family'] == 'inet' }
      end

      def parent_name(link)
        return link['link'] if link['link'].is_a?(String)
        return unless link['link_index'].is_a?(Integer)

        links.values.find { |candidate| candidate['ifindex'] == link['link_index'] }&.fetch('ifname')
      end

      def defaults
        routes.select { |route| %w[default 0.0.0.0/0].include?(route['dst']) }
      end

      def verify_facter!(desired)
        result = command(['/opt/puppetlabs/bin/facter', 'networking', '--json'])
        facts = JSON.parse(result.stdout).fetch('networking').fetch('interfaces')
        desired.each do |name, definition|
          binding = facts.dig(name, 'bindings')&.first
          next if correct_binding?(binding, definition.fetch('network'))

          raise Error, "Host #{@record.fetch('hostname')}, interface #{name}, vm.interfaces: " \
                       'regular Facter networking.interfaces bindings do not match; Puppet was not run'
        end
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError
        raise Error, "Host #{@record.fetch('hostname')}, vm.interfaces: cannot verify regular Facter networking JSON",
              cause: nil
      end

      def correct_binding?(binding, network)
        binding.is_a?(Hash) && binding['address'] == network.split('/').first &&
          binding['netmask'] == IPAddr.new(network).netmask.to_s
      end
    end
  end
end
