# frozen_string_literal: true

module Empeira
  module Node
    module PuppetCommand
      def self.arguments
        [Certificates::PUPPET, 'agent', '--test', '--detailed-exitcodes', '--waitforcert', '0',
         '--color', Execution::Terminal.color? ? 'ansi' : 'false']
      end
    end
  end
end
