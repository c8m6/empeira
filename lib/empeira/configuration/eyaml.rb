# frozen_string_literal: true

module Empeira
  module Configuration
    # Resolve paths without reading or copying key material.
    class Eyaml
      DESTINATION = '/etc/puppetlabs/puppet/eyaml'

      def initialize(config:, project:)
        @config = config
        @project = project
      end

      def mounts(destination: DESTINATION)
        return [] unless @config.fetch('enabled')

        %w[private_key public_key].map do |key|
          source = resolve(key)
          "type=bind,src=#{source},dst=#{destination}/#{key}.pkcs7.pem,readonly"
        end
      end

      private

      def safe_path?(value)
        value.is_a?(String) && !value.empty? && !value.match?(/[\x00-\x1f,]/)
      end

      def resolve(key)
        value = @config[key]
        unless safe_path?(value)
          raise ConfigurationError, "eyaml.#{key} must be a safe local file path when eyaml.enabled=true"
        end

        path = Pathname(value).expand_path(@project).realpath
        unless path.file? && path.readable? && safe_path?(path.to_s)
          raise ConfigurationError, "eyaml.#{key} must be a readable regular file with a safe mount path"
        end

        path
      rescue SystemCallError, ArgumentError
        raise ConfigurationError, "eyaml.#{key} must resolve to a readable regular file", cause: nil
      end
    end
  end
end
