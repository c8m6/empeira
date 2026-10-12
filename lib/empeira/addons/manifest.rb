# frozen_string_literal: true

module Empeira
  module Addons
    class Manifest
      TOKEN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
      OPTION = /\A--?[a-zA-Z0-9][a-zA-Z0-9-]*\z/
      COMPLETIONS = %w[file directory enum none].freeze
      attr_reader :data, :executable

      def initialize(name:, path:)
        @name = name
        @root = Pathname(path).realpath
        manifest = contained!('empeira-addon.yaml', 'manifest')
        @data = Configuration::Document.new.read(manifest)
        validate!
        @executable = contained!(data.fetch('executable'), 'executable')
        fail!('executable is not executable', 126) unless @executable.executable?
        Immutable.deep_freeze(@data)
      rescue ConfigurationError
        fail!('manifest must contain valid, unique YAML data without aliases or object tags')
      rescue SystemCallError
        fail!('installation or manifest is missing or inaccessible')
      end

      private

      def fail!(message, status = 1)
        raise Error.new(@name, message, exit_status: status), cause: nil
      end

      def contained!(relative, label)
        fail!("#{label} must be a relative path without traversal") unless relative?(relative)
        path = @root.join(relative)
        fail!("#{label} is missing", label == 'executable' ? 127 : 1) unless path.file?
        fail!("#{label} escapes the addon directory") unless path.realpath.to_s.start_with?("#{@root}/")
        path.realpath
      end

      def relative?(value)
        value.is_a?(String) && !value.empty? && !value.match?(/[\p{Cc}\p{Cf}]/) &&
          !Pathname(value).absolute? && !value.split('/').intersect?(%w[. ..])
      end

      def validate!
        mapping!(data, %w[schema description executable commands], 'manifest', required: true)
        unless data['schema'].is_a?(Integer) && data['schema'] == 1
          fail!('unsupported manifest schema; expected integer 1')
        end
        text!(data['description'], 'description')
        commands!(data['commands'])
      end

      def commands!(commands)
        fail!('commands must be a mapping') unless commands.is_a?(Hash)
        commands.each do |name, command|
          fail!('invalid command name') unless name.is_a?(String) && name.match?(TOKEN)
          command!(command)
        end
      end

      def command!(command)
        mapping!(command, %w[description arguments options], 'command')
        text!(command['description'], 'command description')
        arguments = command.fetch('arguments', [])
        fail!('arguments must be an array') unless arguments.is_a?(Array)
        arguments.each { |argument| argument!(argument) }
        options!(command.fetch('options', {}))
      end

      def options!(options)
        fail!('options must be a mapping') unless options.is_a?(Hash)
        options.each do |name, value|
          fail!('invalid option name') unless name.is_a?(String) && name.match?(OPTION)
          completion!(value, option: true)
        end
      end

      def argument!(argument)
        completion!(argument)
        name = argument['name']
        fail!('argument requires a name') unless name.is_a?(String) && name.match?(TOKEN)
      end

      def completion!(value, option: false)
        mapping!(value, option ? %w[description completion values] : %w[name completion values], 'completion')
        text!(value['description'], 'option description') if option && value.key?('description')
        fail!('unknown or missing completion type') unless COMPLETIONS.include?(value['completion'])
        return enum!(value['values']) if value['completion'] == 'enum'

        fail!('values are only supported for enum completion') if value.key?('values')
      end

      def enum!(values)
        fail!('enum completion requires an array of values') unless values.is_a?(Array) && !values.empty?
        values.each { |value| text!(value, 'enum value') }
      end

      def mapping!(value, fields, label, required: false)
        return if value.is_a?(Hash) && (value.keys - fields).empty? && (!required || (fields - value.keys).empty?)

        fail!("#{label} has missing or unsupported fields")
      end

      def text!(value, label)
        return if value.is_a?(String) && !value.strip.empty? && !value.match?(/[\p{Cc}\p{Cf}]/)

        fail!("#{label} must be a nonempty string without control characters")
      end
    end
  end
end
