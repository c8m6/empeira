# frozen_string_literal: true

require 'yaml'

module Empeira
  module Configuration
    class Document
      SERVICE_CONTENT = /\Acontainers\.additional\.\d+\.configuration\.content\z/

      def read(path)
        text = File.read(path)
        documents = Psych.parse_stream(text).children
        return {} if documents.empty?
        raise ConfigurationError, 'configuration must contain exactly one YAML document' unless documents.size == 1

        check_keys!(documents.first.root, [])
        YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::Exception
        raise ConfigurationError, "#{File.basename(path)} must contain valid YAML without aliases or object tags"
      rescue SystemCallError
        raise ConfigurationError, "#{File.basename(path)} could not be read"
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Recursively check mapping keys, including service arrays.
      def check_keys!(node, path)
        check_plain_data!(node, path) if path.join('.').match?(SERVICE_CONTENT)
        if node.is_a?(Psych::Nodes::Sequence)
          node.children.each_with_index { |child, index| check_keys!(child, path + [index.to_s]) }
          return
        end
        return unless node.is_a?(Psych::Nodes::Mapping)

        seen = []
        node.children.each_slice(2) do |key, value|
          check_key!(key, path)

          child_path = path + [key.value]
          raise ConfigurationError, "#{location(child_path)} is defined more than once" if seen.include?(key.value)

          seen << key.value
          check_keys!(value, child_path)
        end
      end

      def check_plain_data!(node, path)
        if node.is_a?(Psych::Nodes::Alias) || node.tag || node.anchor
          raise ConfigurationError, "#{location(path)} must not contain YAML tags, anchors or aliases"
        end

        Array(node.children).each { |child| check_plain_data!(child, path) }
      end

      def check_key!(key, path)
        raise ConfigurationError, "#{location(path)} contains a non-string key" unless key.is_a?(Psych::Nodes::Scalar)
        return unless key.value.match?(/[\p{Cc}\p{Cf}]/)

        raise ConfigurationError, "#{location(path)} contains a key with control characters"
      end

      def location(path)
        path.empty? ? '$' : path.join('.')
      end
    end
  end
end
