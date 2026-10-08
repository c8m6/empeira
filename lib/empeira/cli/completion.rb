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
      def candidates(index)
        words = $stdin.read.split("\0", -1)
        words.pop
        cursor = Integer(index, 10) - 1
        return if cursor.negative?

        Empeira::Completion::Catalog.new.candidates(words, cursor).each { |value| say value }
      rescue ArgumentError
        raise Error, 'Completion index must be an integer'
      end
    end
  end
end
