# frozen_string_literal: true

require_relative '../completion/catalog'
require_relative '../completion/bash'

module Empeira
  module CLI
    class Completion < Base
      desc 'bash', 'Print Bash completion for sourcing in your shell'
      def bash
        say Empeira::Completion::Bash.generate
      end

      desc 'candidates INDEX', 'Return completion candidates', hide: true
      option :null, type: :boolean, default: false, hide: true
      def candidates(index)
        words = $stdin.read.split("\0", -1)
        words.pop
        cursor = Integer(index, 10) - 1
        return if cursor.negative?

        emit_candidates(words, cursor)
      rescue ArgumentError
        raise Error, 'Completion index must be an integer'
      end

      no_commands do
        def emit_candidates(words, cursor)
          catalog = Empeira::Completion::Catalog.new
          values = catalog.candidates(words, cursor)
          addon = catalog.addon_completion
          if addon&.file_completion
            values += ["\x1f#{addon.file_completion}", Empeira::Completion::Bash.path_prefix(addon.file_prefix),
                       addon.replacement.to_s]
          end
          separator = options[:null] ? "\0" : "\n"
          values.each { |value| $stdout.write("#{value}#{separator}") }
        end
      end
    end
  end
end
