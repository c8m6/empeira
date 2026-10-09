# frozen_string_literal: true

module Empeira
  module Node
    class PackageBootstrap
      FAMILIES = {
        'ubuntu' => 'debian', 'debian' => 'debian',
        'rhel' => 'redhat', 'rocky' => 'redhat', 'almalinux' => 'redhat', 'oraclelinux' => 'redhat'
      }.freeze
      ACTIONS = %w[install remove].freeze
      GROUPS = %w[default debian redhat].freeze

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Validate the two-level public package matrix in place.
      def self.validate!(value, path = 'bootstrap.packages', effective: false)
        unless valid_keys?(value, ACTIONS, effective)
          raise ConfigurationError, "#{path} must contain only install and remove mappings"
        end

        value.each do |action, groups|
          unless valid_keys?(groups, GROUPS, effective)
            raise ConfigurationError, "#{path}.#{action} must contain only default, debian and redhat arrays"
          end

          groups.each do |family, packages|
            next if packages.is_a?(Array) && packages.all? { |package| valid_package?(package) }

            raise ConfigurationError, "#{path}.#{action}.#{family} must contain valid nonempty package names"
          end
        end
      end

      def self.valid_keys?(value, permitted, effective)
        value.is_a?(Hash) && value.keys.all? { |key| permitted.include?(key) } &&
          (!effective || value.keys.sort == permitted.sort)
      end

      def self.valid_package?(package)
        package.is_a?(String) && package == package.strip && !package.empty? &&
          !package.start_with?('-') && !package.match?(/[\x00-\x20\x7f]/)
      end

      def initialize(config:, os:, execute:, copy: nil, progress: nil, rpm_options: [])
        @config = config
        @os = os
        @execute = execute
        @copy = copy
        @progress = progress || ->(_message) {}
        @rpm_options = rpm_options
      end

      def required?
        ACTIONS.any? { |action| packages(action).any? }
      end

      def run(proxy_url:)
        return unless required?

        @proxy_url = proxy_url
        @package_proxy = PackageProxy.new(family: family, execute: @execute, copy: @copy)
        @package_proxy.prepare(proxy_url)
        execute('remove', packages('remove'))
        execute('update', []) if packages('install').any?
        execute('install', packages('install'))
      ensure
        @package_proxy&.cleanup
      end

      private

      def family
        FAMILIES.fetch(@os) { raise ConfigurationError, "Unsupported package-bootstrap distribution: #{@os}" }
      end

      def packages(action)
        values = @config.fetch(action)
        (values.fetch('default') + values.fetch(family)).uniq
      end

      def execute(action, packages)
        return if action != 'update' && packages.empty?

        @progress.call(progress_message(action, packages.size))
        arguments = command(action, packages)
        result = @execute.call(arguments)
        return if result.success?

        raise_failure(action, result)
      end

      def raise_failure(action, result)
        manager = family == 'debian' ? 'apt-get' : 'dnf'
        text = PackageProxy.redact("#{result.stderr}\n#{result.stdout}", @proxy_url)
        detail = Execution::Diagnostics.native(result.with(stderr: text, stdout: ''),
                                               operation: "Package bootstrap #{action}", tool: manager)
        raise Error, "Package bootstrap #{action} failed with #{manager} " \
                     "(exit=#{result.exit_status}, timeout=#{result.timed_out}); " \
                     "node retained and Puppet was not run\n#{detail}", cause: nil
      end

      def progress_message(action, count)
        return 'Refreshing package metadata...' if action == 'update'

        verb = action == 'remove' ? 'Removing' : 'Installing'
        "#{verb} #{count} package#{'s' unless count == 1}..."
      end

      def command(action, packages)
        return apt_command(action, packages) if family == 'debian'

        dnf_command(action, packages)
      end

      def apt_command(action, packages)
        if action == 'update'
          return ['apt-get', *@package_proxy.arguments, '-o', 'APT::Update::Error-Mode=any',
                  'update']
        end

        ['apt-get', *@package_proxy.arguments, action, '--yes', '--', *packages]
      end

      def dnf_command(action, packages)
        return ['dnf', *@package_proxy.arguments, *@rpm_options, 'makecache'] if action == 'update'

        ['dnf', *@package_proxy.arguments, *@rpm_options, action, '--assumeyes', '--', *packages]
      end
    end
  end
end
