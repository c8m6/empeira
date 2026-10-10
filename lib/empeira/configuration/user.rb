# frozen_string_literal: true

module Empeira
  module Configuration
    # Host preferences only; project behavior remains defined by the control repository.
    class User
      KEYS = { 'runtime' => ['container_engine'].freeze, 'images' => ['registry'].freeze,
               'ssh' => SSHPreferences::KEYS }.freeze

      def initialize(path:, schema: Schema.new)
        @path = path
        @schema = schema
      end

      def load
        return {} unless @path.exist? || @path.symlink?

        data = Document.new.read(@path)
        validate_keys!(data)
        SSHPreferences.validate!(data.fetch('ssh')) if data.key?('ssh')
        @schema.validate_fragment!(data.except('ssh'))
        data
      rescue ConfigurationError => e
        raise ConfigurationError, "#{@path}: #{e.message}", cause: nil
      end

      private

      def validate_keys!(data)
        raise ConfigurationError, '$ must be a mapping' unless data.is_a?(Hash)

        data.each do |section, values|
          reject!(section) unless KEYS.key?(section)
          raise ConfigurationError, "#{section} must be a mapping" unless values.is_a?(Hash)

          values.each_key { |key| reject!("#{section}.#{key}") unless KEYS.fetch(section).include?(key) }
        end
      end

      def reject!(path)
        raise ConfigurationError, "#{path} is not allowed; user configuration may only configure " \
                                  'runtime.container_engine, images.registry and ssh preferences'
      end
    end
  end
end
