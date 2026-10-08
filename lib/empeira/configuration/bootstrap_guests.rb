# frozen_string_literal: true

module Empeira
  module Configuration
    module BootstrapGuests
      def self.validate!(data, path)
        NodeImages.validate!(data, path) do |versions, os_path|
          NodeImages.validate!(versions, os_path) do |guest, guest_path|
            NodeImages.validate!(guest, guest_path) { |value, field| validate_field!(value, field) }
          end
        end
      end

      def self.effective!(data)
        data.each do |os, versions|
          versions.each do |version, guest|
            fields = %w[agent_preinstalled destinations]
            fields << 'baseurl' if %w[rocky almalinux].include?(os)
            NodeImages.required!(guest, fields, "bootstrap.guests.#{os}.#{version}")
          end
        end
      end

      def self.destinations?(value)
        value.is_a?(Array) && value.all? { |domain| Network::ProxyPolicy.valid_domain?(domain) }
      end

      def self.validate_field!(value, field)
        key = field.split('.').last
        valid = case key
                when 'agent_preinstalled' then [true, false].include?(value)
                when 'destinations'
                  destinations?(value)
                when 'archive', 'security', 'ports', 'baseurl'
                  value.is_a?(String) && value.match?(%r{\Ahttps?://[a-z0-9./_-]+\z})
                else false
                end
        raise ConfigurationError, "#{field} is invalid or unsupported" unless valid
      end
    end
  end
end
