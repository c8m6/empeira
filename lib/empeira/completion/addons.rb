# frozen_string_literal: true

module Empeira
  module Completion
    # Only local configuration and declarative manifests; never acquire or execute.
    class Addons
      attr_reader :file_completion, :file_prefix, :replacement

      def initialize(service: Application.new.addons)
        @service = service
      end

      def candidates(words, index, management: false)
        prefix = words[index].to_s
        return @service.names.grep(/^#{Regexp.escape(prefix)}/) if index.zero? || management

        commands = local_commands(words.first)
        return commands.keys.grep(/^#{Regexp.escape(prefix)}/) if index == 1

        command = commands[words[1]]
        command ? command_candidates(command, words[2...index], prefix) : []
      rescue Empeira::Error, SystemCallError
        []
      end

      private

      def local_commands(name)
        manifest = @service.installation(name).local&.last
        manifest ? manifest.data.fetch('commands') : {}
      end

      def command_candidates(command, before, prefix)
        options = command.fetch('options', {})
        position, pending, literal = argument_position(before, options)
        if !literal && prefix.start_with?('-') && !pending
          return assignment(options, prefix) if prefix.include?('=')

          return options.keys.grep(/^#{Regexp.escape(prefix)}/)
        end
        descriptor = pending || command.fetch('arguments', [])[position]
        complete(descriptor, prefix)
      end

      def argument_position(words, options)
        @position = 0
        @pending = nil
        @literal = false
        words.each { |word| consume_word(word, options) }
        [@position, @pending, @literal]
      end

      def consume_word(word, options)
        if @pending
          @pending = nil unless word == '='
          return
        end
        return @position += 1 if @literal

        case word
        when '--' then @literal = true
        when /\A-/ then @pending = option_value(word, options)
        else @position += 1
        end
      end

      def option_value(word, options)
        name, value = word.split('=', 2)
        descriptor = options[name]
        descriptor if descriptor && descriptor['completion'] != 'none' && (value.nil? || value.empty?)
      end

      def assignment(options, prefix)
        name, value = prefix.split('=', 2)
        @replacement = "#{name}="
        complete(options[name], value.to_s).map { |item| "#{@replacement}#{item}" }
      end

      def complete(descriptor, prefix)
        return [] unless descriptor

        case descriptor['completion']
        when 'file', 'directory'
          @file_completion = descriptor['completion']
          @file_prefix = prefix
          []
        when 'enum' then descriptor.fetch('values').grep(/^#{Regexp.escape(prefix)}/)
        else []
        end
      end
    end
  end
end
