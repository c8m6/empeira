# frozen_string_literal: true

require 'securerandom'

module Empeira
  module VM
    # Intent is saved before netlink changes; uncertain transport outcomes are inspected on retry.
    # rubocop:disable-next Metrics/ClassLength -- One locked transaction owns device and parent recovery.
    class Interfaces
      PARENT = Configuration::VMInterfaces::PARENT

      def initialize(context:, record:, state:, guest:, persist:)
        @context = context
        @record = record
        @state = state
        @persist = persist
        @guest = GuestNetwork.new(guest: guest, record: record)
      end

      def self.desired(context, hostname)
        Configuration::VMInterfaces.resolve(context.configuration.dig('vm', 'interfaces'), hostname)
      end

      def self.validate_static!(context, hostname, state)
        definitions = desired(context, hostname)
        InterfaceRoutes.validate_static!(definitions, hostname: hostname, config: context.configuration,
                                                      subnet: state&.dig('peer_network', 'subnet'))
        definitions
      end

      def self.valid_inventory?(inventory)
        return false unless valid_envelope?(inventory)

        inventory['devices'].all? { |name, entry| valid_entry?(name, entry) }
      end

      def self.valid_envelope?(inventory)
        inventory.is_a?(Hash) && inventory.keys.sort_by(&:to_s) == %w[devices parent token] &&
          inventory['token'].is_a?(String) && inventory['token'].match?(/\A[a-f0-9]{32}\z/) &&
          [true, false].include?(inventory['parent']) && inventory['devices'].is_a?(Hash)
      end

      def self.valid_entry?(name, entry)
        return false unless entry.is_a?(Hash) && entry.key?('definition') &&
                            (entry.keys - %w[definition previous]).empty?

        [entry.fetch('definition'), *entry.values_at('previous').compact].each do |definition|
          Configuration::VMInterfaces.device!(name, definition, 'vm.interfaces inventory')
        end
        true
      rescue ConfigurationError
        false
      end

      # rubocop:disable-next Metrics/AbcSize -- Ordered mutations retain inspectable intent on every failure.
      def reconcile
        @desired = self.class.validate_static!(@context, @record.fetch('hostname'), @state)
        return false if @desired.empty? && !@record.key?('network_interfaces')

        prepare_inventory
        observe!
        defaults = @guest.defaults
        @changed = false
        prepare_intents
        prune
        vlan? ? ensure_parent : remove_parent
        @desired.each { |name, definition| apply(name, definition) }
        verify!(defaults)
        @desired.empty? ? release_inventory : @guest.verify_facter!(@desired)
        @changed
      end

      private

      def observe!
        @guest.load_modules(vlan: vlan?) unless @desired.empty?
        @guest.refresh
        names = (@inventory.fetch('devices').keys + @desired.keys + (parent_needed? ? [PARENT] : [])).uniq
        @ownership.validate!(names)
        InterfaceRoutes.new(guest: @guest, ownership: @ownership,
                            hostname: @record.fetch('hostname')).validate!(@desired)
      end

      def release_inventory
        @record.delete('network_interfaces')
        @persist.call
      end

      def prepare_inventory
        unless @record.key?('network_interfaces')
          @record['network_interfaces'] = { 'token' => SecureRandom.hex(16), 'parent' => false, 'devices' => {} }
          @persist.call
        end
        @inventory = @record.fetch('network_interfaces')
        @ownership = InterfaceOwnership.new(context: @context, record: @record, inventory: @inventory, guest: @guest)
      end

      def vlan?
        @desired.values.any? { |definition| definition.key?('vlan_id') }
      end

      def parent_needed?
        vlan? || @inventory.fetch('parent')
      end

      def prune
        # Snapshot names because confirmed removals change this inventory.
        @inventory.fetch('devices').keys.each do |name| # rubocop:disable Style/HashEachMethods
          if @desired.key?(name)
            observed = @ownership.observed_definition(name)
            delete_link(name) if observed && observed != @desired.fetch(name)
            next
          end

          delete_link(name)
          @inventory.fetch('devices').delete(name)
          @persist.call
        end
      end

      def prepare_intents
        @desired.each do |name, definition|
          entry = @inventory.fetch('devices')[name]
          next if entry && entry.fetch('definition') == definition

          observed = @ownership.observed_definition(name)
          @inventory.fetch('devices')[name] = { 'definition' => definition,
                                                **(observed ? { 'previous' => observed } : {}) }
          @persist.call
        end
      end

      def ensure_parent
        unless @inventory.fetch('parent')
          @inventory['parent'] = true
          @persist.call
        end
        create_link(PARENT, {}) unless @guest.links.key?(PARENT)
        activate(PARENT)
      end

      def remove_parent
        return unless @inventory.fetch('parent')

        delete_link(PARENT)
        @inventory['parent'] = false
        @persist.call
      end

      def apply(name, definition)
        entry = @inventory.fetch('devices').fetch(name)
        create_link(name, definition) unless @guest.links.key?(name)
        mark_link(name, definition)
        configure_address(name, definition)
        activate(name)
        @persist.call if entry.delete('previous')
      end

      def create_link(name, definition)
        # Linux applies IFLA_ADDRESS on creation; IFLA_IFALIAS needs a subsequent setlink.
        arguments = ['ip', 'link', 'add', 'name', name, 'address', @ownership.address(name, definition)]
        arguments += if definition.key?('vlan_id')
                       ['link', PARENT, 'type', 'vlan', 'id', definition.fetch('vlan_id').to_s]
                     else
                       %w[type dummy]
                     end
        change(arguments)
        @ownership.observed_definition(name)
      end

      def mark_link(name, definition)
        @ownership.observed_definition(name)
        marker = @ownership.marker(name, definition)
        return if @guest.links.fetch(name)['ifalias'] == marker

        change(['ip', 'link', 'set', 'dev', name, 'alias', marker])
        return if @guest.links.fetch(name)['ifalias'] == marker

        @ownership.conflict!(name, 'ownership alias could not be verified')
      end

      def configure_address(name, definition)
        return unless @guest.ipv4(name).empty?

        change(['ip', 'address', 'add', definition.fetch('network'), 'dev', name])
      end

      def activate(name)
        mark_link(name, @ownership.observed_definition(name))
        return if @guest.links.fetch(name).fetch('flags').include?('UP')

        change(['ip', 'link', 'set', 'dev', name, 'up'])
      end

      def delete_link(name)
        @guest.refresh
        return unless @guest.links.key?(name)

        @ownership.deletable!(name)
        change(['ip', 'link', 'delete', 'dev', name])
        @ownership.conflict!(name, 'deletion could not be verified') if @guest.links.key?(name)
      end

      def change(arguments)
        @guest.command(arguments)
        @changed = true
        @guest.refresh
      end

      def verify!(defaults)
        @guest.refresh
        unless @guest.defaults == defaults
          raise Error, "Host #{@record.fetch('hostname')}, vm.interfaces: default routes changed; Puppet was not run"
        end

        @desired.each { |name, definition| verify_device!(name, definition) }
        return unless @inventory.fetch('parent')

        verify_device!(PARENT, {})
      end

      def verify_device!(name, definition)
        observed = @ownership.observed_definition(name)
        link = @guest.links[name]
        network = definition['network']
        bindings = @guest.ipv4(name).map { |address| "#{address.fetch('local')}/#{address.fetch('prefixlen')}" }
        return if observed == definition && active_link?(name, link, definition) &&
                  bindings == (network ? [network] : [])

        raise Error, "Host #{@record.fetch('hostname')}, interface #{name}, vm.interfaces: " \
                     'guest type, address or active state verification failed; Puppet was not run'
      end

      def active_link?(name, link, definition)
        link.fetch('flags').include?('UP') && link['ifalias'] == @ownership.marker(name, definition) &&
          %w[UP UNKNOWN].include?(link['operstate'])
      end
    end
  end
end
