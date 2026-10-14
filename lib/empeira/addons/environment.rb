# frozen_string_literal: true

require 'etc'

module Empeira
  module Addons
    class Environment
      API_VERSION = '1'

      def initialize(context:, name:, ref:, path:, inherited: ENV.to_h)
        @context = context
        @name = name
        @ref = ref
        @path = path
        @inherited = inherited
      end

      def export(arguments: [])
        environment = @inherited.keys.grep(/^EMPEIRA_/).to_h { |key| [key, nil] }
        flatten(@context.configuration, 'EMPEIRA_CONFIG', [], environment)
        flatten(@context.configuration.dig('addons', @name, 'config') || {}, 'EMPEIRA_ADDON_CONFIG', [], environment)
        environment.merge!(runtime)
        validate_size!(@inherited.merge(environment).compact, arguments)
        environment
      end

      private

      def runtime
        values = { 'EMPEIRA_VERSION' => BuildInfo.load.version, 'EMPEIRA_ADDON_API_VERSION' => API_VERSION,
                   'EMPEIRA_ADDON_NAME' => @name, 'EMPEIRA_ADDON_VERSION' => @ref,
                   'EMPEIRA_ADDON_PATH' => @path.expand_path.to_s }
        values['EMPEIRA_CONTROL_REPO'] = @context.project.path.expand_path.to_s if @context.project
        values['EMPEIRA_WORKSPACE'] = @context.workspace.path.expand_path.to_s if @context.workspace
        values
      end

      def private_path?(path)
        Configuration::Schema::ADDON_PRIVATE_PATHS.any? do |pattern|
          pattern.size == path.size && pattern.zip(path).all? { |expected, key| expected == '*' || expected == key }
        end
      end

      def flatten(value, prefix, path, output)
        return if value.nil? || private_path?(path)

        case value
        when Hash then flatten_mapping(value, prefix, path, output)
        when Array
          output["#{prefix}_COUNT"] = value.size.to_s
          value.each_with_index { |child, index| flatten(child, "#{prefix}_#{index}", path + [index.to_s], output) }
        else output[prefix] = value.to_s
        end
      end

      def flatten_mapping(value, prefix, path, output)
        value.each do |key, child|
          flatten(child, "#{prefix}_#{key.upcase.gsub(/[^A-Z0-9_]/, '_')}", path + [key], output)
        end
      end

      def validate_size!(environment, arguments)
        strings = environment.map { |key, value| "#{key}=#{value}" } + arguments + [@path.to_s]
        if strings.any? { |value| value.include?("\0") }
          raise Error.new(@name, 'configuration environment or arguments contain a null byte')
        end

        return if fits?(strings)

        raise Error.new(@name,
                        'environment and arguments exceed the operating system size limit; ' \
                        'reduce configuration or inherited environment')
      end

      def fits?(strings)
        size = strings.sum { |value| value.bytesize + 1 + 8 }
        limit = Etc.sysconf(Etc::SC_ARG_MAX) || 131_072
        size < limit - 16_384 && strings.all? { |value| value.bytesize < 131_072 }
      end
    end
  end
end
