# frozen_string_literal: true

module Empeira
  module VM
    class InterfaceOwnership
      PARENT = Configuration::VMInterfaces::PARENT

      def initialize(context:, record:, inventory:, guest:)
        @record = record
        @inventory = inventory
        @guest = guest
        node = Digest::SHA256.hexdigest(record.fetch('hostname'))[0, 16]
        @owner = "empeira:#{context.workspace.id}:#{node}:#{inventory.fetch('token')}"
      end

      def marker(name, definition)
        "#{@owner}:#{name}:#{Infrastructure::Definition.fingerprint(definition)}"
      end

      def address(name, definition)
        ['02', *Digest::SHA256.hexdigest(marker(name, definition))[0, 10].scan(/../)].join(':')
      end

      def accepted(name)
        return [{}] if name == PARENT && @inventory.fetch('parent')

        entry = @inventory.fetch('devices')[name]
        entry ? [entry.fetch('definition'), entry['previous']].compact.uniq : []
      end

      def observed_definition(name)
        link = @guest.links[name]
        return unless link

        definition = accepted(name).find { |candidate| marker_matches?(name, link, candidate) }
        unless definition
          conflict!(name,
                    'existing interface is foreign: MAC/alias ownership marker does not match recorded intent')
        end
        unless correct_type?(name, link, definition) && !link.key?('master') && !link.key?('link_netnsid')
          conflict!(name, 'existing interface is foreign, has changed type/parent, or is attached to another network')
        end
        verify_addresses!(name)
        definition
      end

      def marker_matches?(name, link, definition)
        link['address'] == address(name, definition) &&
          (link.fetch('ifalias', '').empty? || link['ifalias'] == marker(name, definition))
      end

      def correct_type?(name, link, definition)
        info = link.fetch('linkinfo', {})
        return info['info_kind'] == 'dummy' if name == PARENT || !definition.key?('vlan_id')

        correct_vlan?(link, info, definition)
      end

      def correct_vlan?(link, info, definition)
        parent = @guest.links[PARENT]
        info['info_kind'] == 'vlan' && info.dig('info_data', 'id') == definition.fetch('vlan_id') &&
          info.dig('info_data', 'protocol').to_s.downcase == '802.1q' && parent && @guest.parent_name(link) == PARENT
      end

      def verify_addresses!(name)
        addresses = @guest.addresses.fetch(name, [])
        networks = accepted(name).filter_map { |definition| definition['network'] }
        return if addresses.all? do |address|
          address['family'] == 'inet' && networks.include?("#{address['local']}/#{address['prefixlen']}")
        end

        conflict!(name, 'interface contains an unowned address; preserve it and investigate')
      end

      def validate!(names)
        names.each { |name| observed_definition(name) }
        validate_markers!(names)
        validate_dependencies!(names)
      end

      def validate_markers!(names)
        @guest.links.each do |name, link|
          next unless owned_marker?(link, names)
          next if names.include?(name)

          conflict!(name, 'owned marker appears on an unrecorded or renamed interface')
        end
      end

      def owned_marker?(link, names)
        link.fetch('ifalias', '').start_with?("#{@owner}:") || names.any? do |name|
          accepted(name).any? { |definition| link['address'] == address(name, definition) }
        end
      end

      def validate_dependencies!(names)
        names.each do |name|
          link = @guest.links[name]
          next unless link

          children = @guest.links.values.select { |child| @guest.parent_name(child) == name }
          children.each do |child|
            child_name = child.fetch('ifname')
            conflict!(name, "dependent interface #{child_name} is foreign") unless names.include?(child_name)
          end
        end
      end

      def deletable!(name)
        observed_definition(name)
        link = @guest.links[name]
        return unless link
        return unless @guest.links.values.any? { |child| @guest.parent_name(child) == name }

        conflict!(name, 'dependent interfaces still exist; parent deletion refused')
      end

      def conflict!(name, reason)
        raise Providers::OwnershipError,
              "Host #{@record.fetch('hostname')}, interface #{name}, vm.interfaces: #{reason}"
      end
    end
  end
end
