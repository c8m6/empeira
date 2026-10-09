# frozen_string_literal: true

module Empeira
  module Agent
    class Target < Data.define(:os, :release, :architecture)
      SUITES = { '22.04' => 'jammy', '24.04' => 'noble' }.freeze
      ARCHITECTURES = { 'amd64' => 'x86_64', 'arm64' => 'aarch64' }.freeze

      def family
        Node::PackageBootstrap::FAMILIES.fetch(os)
      end

      def format
        family == 'debian' ? 'deb' : 'rpm'
      end

      def native_architecture
        family == 'debian' ? architecture : ARCHITECTURES.fetch(architecture)
      end

      def key
        family == 'debian' ? "#{os}#{release}" : "el#{release}"
      end

      def expand(value)
        values = { 'suite' => SUITES[release], 'releasever' => release, 'basearch' => native_architecture }
        value.gsub(/\$(?:\{([^}]+)\}|([a-zA-Z_][a-zA-Z_0-9]*))/) do
          values.fetch(Regexp.last_match(1) || Regexp.last_match(2)) do
            raise ConfigurationError, 'Unknown agent repository placeholder'
          end || raise(ConfigurationError, 'Agent repository suite is unavailable for this target')
        end
      end

      def source(install)
        return package_source(install) if install.fetch('method') == 'package'

        manager = family == 'debian' ? 'apt' : 'dnf'
        sources = install.fetch(manager)
        return install.fetch('repositories').fetch(key) unless configured?(sources)

        resolved = Configuration::Merge.call(sources.fetch('default', {}), sources.fetch(key, {}),
                                             path: ['agent', 'install', manager, key])
        expand_source(resolved)
      end

      private

      def package_source(install)
        install.fetch('packages').fetch(key).fetch(architecture)
      end

      def configured?(sources)
        sources.key?('default') || sources.key?(key)
      end

      def expand_source(source)
        resolved = source.transform_values { |value| value.is_a?(String) ? expand(value) : value }
        if family == 'debian'
          resolved['suite'] ||= SUITES.fetch(release)
          resolved['component'] ||= 'main'
        end
        resolved
      end
    end
  end
end
