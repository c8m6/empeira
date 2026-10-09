# frozen_string_literal: true

module Empeira
  module Network
    # Observed owned service addresses are transient gateway inputs, never inventory mappings.
    class Redirects
      EXCLUDED_TARGETS = %w[gateway browser-ui].freeze

      def self.validate!(entries, definitions:, subnet: nil)
        entries.each_with_index do |entry, index|
          path = "network.redirects[#{index}]"
          target = entry.fetch('to').fetch('service')
          unless definitions.key?(target) && !EXCLUDED_TARGETS.include?(target)
            raise ConfigurationError, "#{path}.to.service #{target} is missing, disabled or not an internal " \
                                      'application service'
          end
          next unless subnet && IPAddr.new(subnet).include?(entry.fetch('from').fetch('ip'))

          raise ConfigurationError, "#{path}.from.ip collides with the workspace subnet #{subnet}"
        end
      end

      def initialize(entries:, network:, subnet:)
        @entries = entries
        @network = network
        @subnet = IPAddr.new(subnet)
      end

      def resolve(definitions:, resources:)
        entries = @entries.map do |entry|
          key = entry.fetch('to').fetch('service')
          resource = resources[key]
          ip = target_address(resource, definitions.fetch(key))
          { 'from' => entry.fetch('from'), 'to' => ip && { 'ip' => ip, 'port' => entry.fetch('to').fetch('port') } }
        end
        entries.sort_by { |entry| entry.fetch('from').values_at('ip', 'port') }
      end

      private

      def target_address(resource, definition)
        return unless resource

        definition.verify!(resource)
        return unless resource['state'] == 'running' &&
                      resource.dig('labels', 'io.empeira.definition') == definition.fingerprint

        ip = resource.dig('networks', @network, 'IPAddress')
        unless valid_address?(ip)
          raise Providers::OwnershipError, "Redirect target #{definition.key} has no valid workspace IPv4 address"
        end

        ip
      rescue IPAddr::InvalidAddressError
        raise Providers::OwnershipError, "Redirect target #{definition.key} has an invalid workspace address",
              cause: nil
      end

      def valid_address?(ip)
        ip.is_a?(String) && @subnet.include?(IPAddr.new(ip)) && IPAddr.new(ip).to_s == ip
      end
    end
  end
end
