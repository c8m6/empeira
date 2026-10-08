# frozen_string_literal: true

require 'uri'

module Empeira
  module Configuration
    # Validates the independent agent package and its acquisition sources.
    # rubocop:disable-next Metrics/ModuleLength -- One public agent namespace owns its source formats.
    module AgentSchema
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
          when 'package', 'version' then token!(value, field)
          when 'install' then install!(value, field)
          else raise ConfigurationError, "#{field} is unsupported"
          end
        end
      end

      def effective!(data)
        required!(data, %w[package version install], 'agent')
        install = data.fetch('install')
        required!(install, %w[method repositories apt dnf packages], 'agent.install')
        install.fetch('repositories').each do |key, source|
          required!(source, %w[url sha256 suffix destinations], "agent.install.repositories.#{key}")
        end
        return unless install.fetch('method') == 'package' && install.fetch('packages').empty?

        raise ConfigurationError, 'agent.install.packages must define at least one distribution and architecture'
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- Each supported install source has its own validator.
      def install!(data, path)
        mapping!(data, path)
        data.each do |key, value|
          field = "#{path}.#{key}"
          case key
          when 'method'
            raise ConfigurationError, "#{field} must be repository or package" unless %w[repository
                                                                                         package].include?(value)
          when 'repositories' then catalog!(value, field) { |source, source_path| release_source!(source, source_path) }
          when 'apt' then catalog!(value, field) { |source, source_path| apt_source!(source, source_path) }
          when 'dnf' then catalog!(value, field) { |source, source_path| dnf_source!(source, source_path) }
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

            artifact!(artifact, artifact_path)
            family = os_path.delete_prefix("#{path}.")
            extension = family.start_with?('ubuntu', 'debian') ? '.deb' : '.rpm'
            unless URI(artifact.fetch('url')).path.end_with?(extension)
              raise ConfigurationError, "#{artifact_path}.url must end in #{extension}"
            end
          end
        end
      end

      def artifact!(data, path)
        mapping!(data, path)
        raise ConfigurationError, "#{path} requires url and sha256" unless data.keys.sort == %w[sha256 url]

        https_url!(data.fetch('url'), "#{path}.url")
        digest!(data.fetch('sha256'), "#{path}.sha256")
      end

      def release_source!(data, path)
        mapping!(data, path)
        data.each do |key, value|
          field = "#{path}.#{key}"
          case key
          when 'url' then https_url!(value, field)
          when 'sha256' then digest!(value, field)
          when 'suffix' then suffix!(value, field)
          when 'destinations'
            raise ConfigurationError, "#{field} must contain valid proxy destination domains" unless
              BootstrapGuests.destinations?(value)
          else raise ConfigurationError, "#{field} is unsupported"
          end
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Validate the signed APT source as one atomic mapping.
      def apt_source!(data, path)
        mapping!(data, path)
        allowed = %w[url suite component suffix release key]
        raise ConfigurationError, "#{path} has unsupported fields" unless (data.keys - allowed).empty?

        required!(data, %w[url suite component suffix], path)
        https_url!(data['url'], "#{path}.url")
        %w[suite component].each { |key| token!(data[key], "#{path}.#{key}") }
        suffix!(data['suffix'], "#{path}.suffix")
        unless data.key?('release') ^ data.key?('key')
          raise ConfigurationError, "#{path} requires exactly one of release or key"
        end

        artifact!(data.fetch(data.key?('release') ? 'release' : 'key'),
                  "#{path}.#{data.key?('release') ? 'release' : 'key'}")
      end

      # rubocop:disable-next Metrics/AbcSize -- Validate the signed DNF source as one atomic mapping.
      def dnf_source!(data, path)
        mapping!(data, path)
        raise ConfigurationError, "#{path} requires url, suffix and key" unless data.keys.sort == %w[key suffix url]

        url = data['url']
        https_url!(url.gsub('$basearch', 'x86_64'), "#{path}.url") if url.is_a?(String)
        unless url.is_a?(String) && url.match?(%r{\Ahttps://[a-zA-Z0-9.-]+(?::[0-9]+)?/[a-zA-Z0-9_./$-]+\z}) &&
               !url.include?('..') && !url.gsub('$basearch', '').include?('$')
          raise ConfigurationError, "#{path}.url must be a credential-free HTTPS DNF base URL"
        end

        suffix!(data['suffix'], "#{path}.suffix")
        artifact!(data['key'], "#{path}.key")
      end

      def required!(data, keys, path)
        keys.each { |key| raise ConfigurationError, "#{path}.#{key} is required" unless data.key?(key) }
      end

      def token!(value, path)
        return if value.is_a?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.+-]*\z/)

        raise ConfigurationError, "#{path} must be a package/version token"
      end

      def suffix!(value, path)
        return if value.is_a?(String) && value.match?(/\A[-+a-zA-Z0-9.]+\z/)

        raise ConfigurationError, "#{path} is invalid"
      end

      def digest!(value, path)
        return if value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)

        raise ConfigurationError, "#{path} must be a SHA-256 digest"
      end

      def https_url!(value, path)
        uri = URI(value)
        return if uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        raise ConfigurationError, "#{path} must be a credential-free HTTPS URL"
      rescue URI::InvalidURIError, TypeError
        raise ConfigurationError, "#{path} must be a credential-free HTTPS URL"
      end
    end
  end
end
