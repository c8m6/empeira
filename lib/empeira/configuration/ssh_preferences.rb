# frozen_string_literal: true

require 'pathname'

module Empeira
  module Configuration
    # Personal login preferences are resolved independently of infrastructure definitions.
    class SSHPreferences
      FIELDS = %w[user identity port].freeze
      KEYS = [*FIELDS, 'rules'].freeze
      USER = /\A[a-zA-Z0-9_.@-]+\z/

      def self.validate!(data, path = 'ssh')
        mapping!(data, KEYS, path)
        fields!(data, path)
        rules = data.fetch('rules', [])
        raise ConfigurationError, "#{path}.rules must be an array" unless rules.is_a?(Array)

        rules.each_with_index { |rule, index| rule!(rule, "#{path}.rules.#{index}") }
      end

      def self.mapping!(data, keys, path)
        raise ConfigurationError, "#{path} must be a mapping" unless data.is_a?(Hash)

        data.each_key do |key|
          raise ConfigurationError, "#{path} contains a non-string key" unless key.is_a?(String)
          raise ConfigurationError, "#{path}.#{key} is not a supported configuration key" unless keys.include?(key)
        end
      end

      def self.fields!(data, path)
        if data.key?('user') && !(data['user'].is_a?(String) && data['user'].match?(USER))
          raise ConfigurationError, "#{path}.user must be a valid login name"
        end

        identity!(data['identity'], path) if data.key?('identity')
        port!(data['port'], "#{path}.port") if data.key?('port')
      end

      def self.port!(value, path = 'SSH port')
        return value if value.is_a?(Integer) && value.between?(1, 65_535)

        raise ConfigurationError, "#{path} must be an integer from 1 to 65535"
      end

      def self.identity!(value, path)
        return if value.is_a?(String) && !value.match?(/[\p{Cc}\p{Cf}]/) &&
                  (value.start_with?('~/') || Pathname(value).absolute?)

        raise ConfigurationError, "#{path}.identity must be an absolute path or start with ~/"
      end

      def self.rule!(rule, path)
        mapping!(rule, [*FIELDS, 'hosts'], path)
        fields!(rule, path)
        unless rule.keys.intersect?(FIELDS)
          raise ConfigurationError, "#{path} requires at least one of user, identity or port"
        end

        hosts = rule['hosts']
        return if hosts.is_a?(Array) && !hosts.empty? && hosts.all? { |pattern| HostnamePattern.valid?(pattern) }

        raise ConfigurationError, "#{path}.hosts must contain full hostname globs using * and ?"
      end

      def initialize(config = {})
        @config = config
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Three independent preference fields share one matcher.
      def resolve(hostname:, user: nil, identity: nil, port: nil)
        self.class.port!(port) unless port.nil?
        fields = @config.slice(*FIELDS)
        @config.fetch('rules', []).each do |rule|
          fields.merge!(rule.slice(*FIELDS)) if rule.fetch('hosts').any? do |pattern|
            HostnamePattern.matches?(pattern, hostname)
          end
        end
        { user: user || fields['user'], identity: identity || fields['identity'], port: port || fields['port'] }
      end
    end
  end
end
