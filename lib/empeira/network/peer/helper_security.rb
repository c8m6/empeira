# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      module HelperSecurity
        def self.verify!(resource, privileged_tap:)
          config = resource.fetch('host_config')
          return if base_valid?(config) && resource.fetch('mounts').empty? &&
                    capabilities_valid?(config, privileged_tap) && devices_valid?(config, privileged_tap)

          raise Providers::OwnershipError, 'Peer helper privileges or mounts differ from the managed definition'
        end

        def self.base_valid?(config)
          config['Privileged'] == false && config['ReadonlyRootfs'] == true &&
            Array(config['SecurityOpt']).include?('no-new-privileges')
        end

        def self.capabilities_valid?(config, tap)
          caps = Array(config['CapAdd']).map { |cap| cap.delete_prefix('CAP_') }
          dropped = Array(config['CapDrop'])
          return dropped == ['ALL'] && caps == ['NET_ADMIN'] if tap

          !dropped.empty? && caps.empty?
        end

        def self.devices_valid?(config, tap)
          devices = Array(config['Devices'])
          return devices.empty? unless tap

          devices.size == 1 && devices.first['PathOnHost'] == '/dev/net/tun' &&
            devices.first['PathInContainer'] == '/dev/net/tun' &&
            config.dig('Sysctls', 'net.ipv4.ip_forward') == '0' &&
            config.dig('Sysctls', 'net.ipv6.conf.all.disable_ipv6') == '1'
        end
      end
    end
  end
end
