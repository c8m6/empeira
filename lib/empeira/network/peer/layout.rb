# frozen_string_literal: true

require 'ipaddr'
require 'securerandom'

module Empeira
  module Network
    module Peer
      # Addresses belong to node instances, under the existing workspace mutation lock.
      class Layout
        attr_reader :subnet

        def initialize(subnet)
          @subnet = subnet
          @range = IPAddr.new(subnet)
          unless @range.ipv4? && @range.private? && @range.prefix == 24 && "#{@range}/24" == subnet
            raise Infrastructure::StateError, 'Invalid workspace peer subnet'
          end
        rescue IPAddr::InvalidAddressError
          raise Infrastructure::StateError, 'Invalid workspace peer subnet', cause: nil
        end

        def address(offset)
          IPAddr.new(@range.to_i + offset, Socket::AF_INET).to_s
        end

        def container_pool
          "#{address(128)}/25"
        end

        def lease(nodes)
          used = nodes.values.filter_map { |record| record.dig('peer', 'ip') }
          ip = (32..95).map { |offset| address(offset) }.find { |candidate| !used.include?(candidate) }
          raise Error, 'Workspace VM address pool exhausted; destroy an unused VM to release its lease' unless ip

          { 'ip' => ip, 'token' => SecureRandom.hex(16), 'adapter_id' => nil }
        end

        def container_lease(nodes)
          used = nodes.values.filter_map { |record| record.dig('definition', 'ip') }
          ip = (96..127).map { |offset| address(offset) }.find { |candidate| !used.include?(candidate) }
          raise Error, 'Workspace container node pool exhausted; destroy an unused node' unless ip

          ip
        end

        def valid_lease?(entry)
          entry.is_a?(Hash) && (32..95).any? { |offset| address(offset) == entry['ip'] } &&
            entry['token'].is_a?(String) && entry['token'].match?(/\A[0-9a-f]{32}\z/) &&
            Node::Inventory.valid_id?(entry['adapter_id'])
        end
      end
    end
  end
end
