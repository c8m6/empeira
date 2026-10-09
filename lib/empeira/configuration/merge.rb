# frozen_string_literal: true

module Empeira
  module Configuration
    module Merge
      module_function

      def call(lower, higher, path: [])
        lower = agent_override_base(lower, higher, path)
        lower = ImageSchema.override_base(lower, higher) if path.first == 'images' && path.size == 2
        copy(lower).merge(copy(higher)) do |key, old, replacement|
          old.is_a?(Hash) && replacement.is_a?(Hash) ? call(old, replacement, path: path + [key]) : replacement
        end
      end

      def agent_override_base(lower, higher, path)
        return lower unless path.first == 'agent'

        base = copy(lower)
        if path == %w[agent install]
          override_agent_defaults!(base, higher)
        elsif higher.key?('url') && higher['url'] != base['url'] && !higher.key?('sha256')
          base.delete('sha256')
        end
        base
      end

      def override_agent_defaults!(base, higher)
        %w[apt dnf].each do |manager|
          next unless higher.dig(manager, 'default', 'url')

          prefix = manager == 'apt' ? /\A(?:ubuntu|debian)/ : /\Ael/
          base.fetch('repositories', {}).delete_if { |key, _| key.match?(prefix) }
          base.fetch(manager, {}).clear
        end
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, child| [copy(key), copy(child)] }
        when Array then value.map { |child| copy(child) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
