# frozen_string_literal: true

module Empeira
  module Network
    class HostPolicy
      def self.validate!(rules, path = 'proxy.rules')
        raise ConfigurationError, "#{path} must be an array" unless rules.is_a?(Array)

        rules.each_with_index { |rule, index| validate_rule!(rule, "#{path}.#{index}") }
      end

      def self.validate_rule!(rule, location)
        raise ConfigurationError, "#{location} requires hosts and allow arrays" unless valid_rule_keys?(rule)
        unless valid_hosts?(rule['hosts'])
          raise ConfigurationError, "#{location}.hosts must contain lowercase hostname globs using * and ?"
        end
        return if rule['allow'].is_a?(Array) && rule['allow'].all? { |v| ProxyPolicy.valid_domain?(v) }

        raise ConfigurationError, "#{location}.allow must contain DNS domains or *.domain entries"
      end

      def self.valid_rule_keys?(rule)
        rule.is_a?(Hash) && rule.keys.sort_by(&:to_s) == %w[allow hosts]
      end

      def self.valid_hosts?(hosts)
        hosts.is_a?(Array) && !hosts.empty? && hosts.all? { |v| valid_glob?(v) }
      end

      def self.valid_glob?(value)
        value.is_a?(String) && value.size.between?(1, 253) && value.match?(/\A[a-z0-9*?][a-z0-9.*?-]*\z/)
      end

      def initialize(config)
        @config = config
      end

      def matching(hostname)
        @config.fetch('rules').select do |rule|
          rule.fetch('hosts').any? { |pattern| File.fnmatch?(pattern, hostname.downcase) }
        end
      end

      def resolve(hostname)
        (@config.fetch('global') + matching(hostname).flat_map { |rule| rule.fetch('allow') }).uniq
      end
    end
  end
end
