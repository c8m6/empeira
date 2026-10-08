# frozen_string_literal: true

module Empeira
  module Configuration
    # Node image metadata and architecture validation.
    module NodeImages
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

      def validate!(value, path, &)
        catalog!(value, path, &)
      end

      def nodes(data, path)
        catalog!(data, path) do |versions, os_path|
          catalog!(versions, os_path) do |image, image_path|
            node_image!(image, image_path)
          end
        end
      end

      def node_image!(image, path)
        mapping!(image, path)
        ImageSchema.validate!(image.except('architectures', 'build'), path)
        ImageSchema.validate!({ 'build' => image['build'] }, path) if image.key?('build')
        return unless image.key?('architectures')

        architectures = image['architectures']
        return if architectures.is_a?(Array) && !architectures.empty? &&
                  (architectures - %w[amd64 arm64]).empty?

        raise ConfigurationError, "#{path}.architectures must contain amd64 and/or arm64"
      end

      def effective!(images)
        images.fetch('nodes').each do |os, versions|
          versions.each do |version, image|
            path = "images.nodes.#{os}.#{version}"
            required!(image, ['architectures'], path)
            ImageSchema.validate!(image.except('architectures', 'build'), path, effective: true)
          end
        end
      end

      def required!(data, keys, path)
        keys.each { |key| raise ConfigurationError, "#{path}.#{key} is required" unless data.key?(key) }
      end
    end
  end
end
