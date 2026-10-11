# frozen_string_literal: true

require 'ipaddr'

module Empeira
  module Configuration
    # rubocop:disable-next Metrics/ClassLength -- Fragment validation and matching share one configuration contract.
    class VMInterfaces
      PARENT = 'empeira-vlan'
      RESERVED = %w[lo eth0 peer].push(PARENT).freeze
      UNSUITABLE = %w[0.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
                      192.0.0.0/24 192.88.99.0/24 224.0.0.0/3].map { |value| IPAddr.new(value) }.freeze

      def self.validate!(rules, path = 'vm.interfaces')
        raise ConfigurationError, "#{path} must be an array" unless rules.is_a?(Array)

        rules.each_with_index { |rule, index| validate_rule!(rule, "#{path}[#{index}]") }
      end

      def self.validate_rule!(rule, path)
        unless rule.is_a?(Hash) && rule.keys.sort_by(&:to_s) == %w[devices hosts]
          raise ConfigurationError, "#{path} requires only hosts and devices"
        end

        hosts = rule.fetch('hosts')
        raise ConfigurationError, "#{path}.hosts must contain hostname globs using * and ?" unless valid_hosts?(hosts)

        validate_devices!(rule.fetch('devices'), path, hosts)
      end

      def self.valid_hosts?(hosts)
        hosts.is_a?(Array) && !hosts.empty? && hosts.all? { |host| valid_pattern?(host) }
      end

      def self.validate_devices!(devices, path, hosts)
        unless devices.is_a?(Hash) && !devices.empty?
          raise ConfigurationError, "#{path}.devices must be a nonempty mapping"
        end

        devices.each do |name, definition|
          device!(name, definition, "#{path}.devices.#{name}")
        end
        unique!(devices, path)
      rescue ConfigurationError => e
        raise ConfigurationError, "#{e.message} (hosts: #{hosts.join(', ')})", cause: nil
      end

      def self.valid_pattern?(value)
        value.is_a?(String) && Network::HostPolicy.valid_glob?(value.downcase)
      end

      def self.device!(name, definition, path)
        unless valid_name?(name)
          raise ConfigurationError, "#{path}: interface must use 1-15 ASCII letters, digits, _, . or -, " \
                                    'start with a letter or digit, and not use a reserved Empeira name'
        end
        unless valid_definition_keys?(definition)
          raise ConfigurationError, "#{path} requires network and permits only optional vlan_id"
        end

        network!(definition.fetch('network'), "#{path}.network")
        return unless definition.key?('vlan_id')

        vlan!(definition['vlan_id'], path)
      end

      def self.valid_definition_keys?(definition)
        definition.is_a?(Hash) && definition.key?('network') && (definition.keys - %w[network vlan_id]).empty?
      end

      def self.vlan!(value, path)
        return if value.is_a?(Integer) && value.between?(1, 4094)

        raise ConfigurationError, "#{path}.vlan_id must be an integer from 1 through 4094"
      end

      def self.valid_name?(name)
        name.is_a?(String) && name.bytesize.between?(1, 15) &&
          name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/) && !RESERVED.include?(name)
      end

      def self.network!(value, path)
        unless value.is_a?(String) && value.match?(%r{\A(?:\d{1,3}\.){3}\d{1,3}/(?:[0-9]|[12][0-9]|3[0-2])\z})
          raise ConfigurationError, "#{path} must be a canonical IPv4 host address with CIDR prefix (IPv6 unsupported)"
        end

        address = IPAddr.new(value.split('/').first)
        subnet = IPAddr.new(value)
        valid = address.ipv4? && address.to_s == value.split('/').first && usable_host?(address, subnet)
        raise ConfigurationError, "#{path} must be a usable unicast IPv4 host address and subnet" unless valid
      rescue IPAddr::InvalidAddressError
        raise ConfigurationError, "#{path} must be a valid IPv4 host address with CIDR prefix", cause: nil
      end

      def self.usable_host?(address, subnet)
        UNSUITABLE.none? { |range| overlap?(range, subnet) } &&
          (subnet.prefix >= 31 || ![subnet.to_range.first, subnet.to_range.last].include?(address))
      end

      def self.overlap?(left, right)
        left.include?(right.to_range.first) || right.include?(left.to_range.first)
      end

      # One parent cannot carry two devices with the same VLAN ID.
      def self.unique!(devices, path)
        %w[network vlan_id].each { |key| unique_value!(devices, key, path) }
        devices.to_a.combination(2) do |(left_name, left), (right_name, right)|
          next unless overlap?(IPAddr.new(left.fetch('network')), IPAddr.new(right.fetch('network')))

          raise ConfigurationError, "#{path}: interfaces #{left_name} and #{right_name} have overlapping networks"
        end
      end

      def self.unique_value!(devices, key, path)
        groups = devices.group_by { |_, definition| definition[key].to_s.split('/').first }
        groups.each do |value, entries|
          next if value.nil? || entries.size == 1

          raise ConfigurationError, "#{path}: devices #{entries.map(&:first).join(', ')} have duplicate #{key} #{value}"
        end
      end

      def self.resolve(rules, hostname)
        devices = {}
        paths = {}
        rules.each_with_index do |rule, index|
          next unless rule.fetch('hosts').any? { |pattern| Network::HostPolicy.matches?(pattern, hostname) }

          rule.fetch('devices').each do |name, definition|
            path = "vm.interfaces[#{index}].devices.#{name}"
            compatible!(devices, name, definition, hostname, path, paths[name])
            devices[name] = definition
            paths[name] ||= path
          end
        end
        unique!(devices, "vm.interfaces (host #{hostname})")
        devices
      end

      def self.compatible!(devices, name, definition, hostname, path, previous)
        return unless devices.key?(name) && devices[name] != definition

        raise ConfigurationError, "Host #{hostname}, interface #{name}: #{path} conflicts with #{previous}"
      end
    end
  end
end
