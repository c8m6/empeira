# frozen_string_literal: true

require 'uri'

module Empeira
  module Configuration
    # Fragment validation allows partial OS overrides; effective validation checks the resolved source.
    # rubocop:disable-next Metrics/ModuleLength -- Keep fragment and effective validation of this source contract together.
    module AgentSchema
      extend AgentValues

      SOURCE_VALIDATORS = { 'url' => :template_url!, 'sha256' => :digest!, 'suffix' => :suffix!,
                            'suite' => :token!, 'component' => :token!, 'key' => :artifact!,
                            'release' => :artifact!, 'verify_signatures' => :boolean!,
                            'destinations' => :destinations! }.freeze

      module_function

      def mapping!(value, path)
        raise ConfigurationError, "#{path} must be a mapping" unless value.is_a?(Hash)
      end

      def catalog!(value, path)
        mapping!(value, path)
        value.each do |key, item|
          unless key.is_a?(String) && key.match?(/\A[a-z0-9][a-z0-9_.-]*\z/)
            raise ConfigurationError, "#{path} has an invalid catalog key"
          end

          yield item, "#{path}.#{key}"
        end
      end

      def validate!(data, path)
        mapping!(data, path)
        data.each do |key, value|
          field = "#{path}.#{key}"
          case key
          when 'package' then package_token!(value, field)
          when 'version' then token!(value, field)
          when 'cache' then cache!(value, field)
          when 'install' then install!(value, field)
          else raise ConfigurationError, "#{field} is unsupported"
          end
        end
      end

      def cache!(data, path)
        mapping!(data, path)
        data.each do |key, value|
          raise ConfigurationError, "#{path}.#{key} is unsupported" unless key == 'enabled'

          boolean!(value, "#{path}.enabled")
        end
      end

      def effective!(data)
        required!(data, %w[package version cache install], 'agent')
        required!(data.fetch('cache'), ['enabled'], 'agent.cache')
        install = data.fetch('install')
        required!(install, %w[method repositories apt dnf packages], 'agent.install')
        install.fetch('repositories').each do |key, source|
          required!(source, ['url'], "agent.install.repositories.#{key}")
        end
        %w[apt dnf].each { |manager| effective_sources!(install.fetch(manager), "agent.install.#{manager}") }
        return unless install.fetch('method') == 'package' && install.fetch('packages').empty?

        raise ConfigurationError, 'agent.install.packages must define at least one distribution and architecture'
      end

      def effective_sources!(sources, path)
        sources.each do |key, source|
          resolved = Merge.call(sources.fetch('default', {}), source, path: [*path.split('.'), key])
          required!(resolved, ['url'], "#{path}.#{key}")
          source!(resolved, "#{path}.#{key}", manager: path.split('.').last)
        end
      end

      def install!(data, path)
        mapping!(data, path)
        data.each do |key, value|
          field = "#{path}.#{key}"
          case key
          when 'method'
            raise ConfigurationError, "#{field} must be repository or package" unless %w[repository
                                                                                         package].include?(value)
          when 'repositories' then catalog!(value, field) { |source, source_path| source!(source, source_path) }
          when 'apt', 'dnf' then catalog!(value, field) do |source, source_path|
            source!(source, source_path, manager: key)
          end
          when 'packages' then package_sources!(value, field)
          else raise ConfigurationError, "#{field} is unsupported"
          end
        end
      end

      def package_sources!(data, path)
        catalog!(data, path) do |architectures, os_path|
          catalog!(architectures, os_path) do |artifact, artifact_path|
            raise ConfigurationError, "#{artifact_path} has unsupported architecture" unless
              %w[amd64 arm64].include?(artifact_path.split('.').last)

            artifact!(artifact, artifact_path, package: true)
            family = os_path.delete_prefix("#{path}.")
            extension = family.start_with?('ubuntu', 'debian') ? '.deb' : '.rpm'
            unless URI(artifact.fetch('url')).path.end_with?(extension)
              raise ConfigurationError, "#{artifact_path}.url must end in #{extension}"
            end
          end
        end
      end

      def artifact!(data, path, package: false)
        mapping!(data, path)
        allowed = package ? %w[url sha256 verify_signatures key] : %w[url sha256]
        fields!(data, allowed, path)

        required!(data, ['url'], path)
        https_url!(data.fetch('url'), "#{path}.url")
        digest!(data['sha256'], "#{path}.sha256") if data.key?('sha256')
        boolean!(data['verify_signatures'], "#{path}.verify_signatures") if data.key?('verify_signatures')
        artifact!(data['key'], "#{path}.key") if data.key?('key')
      end

      def source!(data, path, manager: nil)
        mapping!(data, path)
        allowed = %w[url sha256 suffix destinations verify_signatures]
        allowed += %w[suite component release key] if manager == 'apt'
        allowed += ['key'] if manager == 'dnf'
        fields!(data, allowed, path)
        data.each { |key, value| public_send(SOURCE_VALIDATORS.fetch(key), value, "#{path}.#{key}") }
        return unless data.key?('release') && data.key?('key')

        raise ConfigurationError, "#{path} cannot specify both release and key"
      end

      def destinations!(value, path)
        raise ConfigurationError, "#{path} must contain valid proxy destination domains" unless
          BootstrapGuests.destinations?(value)
      end

      def fields!(data, allowed, path)
        key = (data.keys - allowed).first
        raise ConfigurationError, "#{path}.#{key} is unsupported" if key
      end

      def template_url!(value, path)
        raise ConfigurationError, "#{path} must be a credential-free HTTPS URL" unless value.is_a?(String)

        expanded = value.gsub(/\$(?:\{([^}]+)\}|([a-zA-Z_][a-zA-Z_0-9]*))/) do
          name = Regexp.last_match(1) || Regexp.last_match(2)
          raise ConfigurationError, "#{path} has unknown placeholder #{name}" unless %w[suite releasever
                                                                                        basearch].include?(name)

          'target'
        end
        raise ConfigurationError, "#{path} has an invalid placeholder" if expanded.include?('$')

        https_url!(expanded, path)
      end
    end
  end
end
