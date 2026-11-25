# frozen_string_literal: true

require 'json'
require 'pathname'

module Empeira
  module Node
    # Agent tools are exposed through owned interactive OS startup fragments.
    class InteractiveTools
      def initialize(record:, execute:, persist:)
        @record = record
        @execute = execute
        @persist = persist
      end

      def self.valid_inventory?(entry)
        entry == { 'version' => 1 }
      end

      def reconcile
        helper = Pathname(__dir__).join('../../../resources/nodes/interactive_tools.rb').read
        prepare_inventory
        result = @execute.call([Certificates::RUBY, '-e', helper, JSON.generate('puppet' => Certificates::PUPPET)])
        unless result.success?
          details = Execution::Diagnostics.command(result, operation: 'Interactive agent tool PATH', tool: 'ruby')
          raise Error, "Cannot configure interactive agent tools; node retained for diagnosis\n#{details}", cause: nil
        end

        JSON.parse(result.stdout).fetch('changed')
      rescue JSON::ParserError, KeyError
        raise Error, 'Cannot verify interactive agent tool PATH; node retained for diagnosis', cause: nil
      end

      private

      def prepare_inventory
        return if self.class.valid_inventory?(@record['interactive_tools'])

        @record['interactive_tools'] = { 'version' => 1 }
        @persist.call
      end
    end
  end
end
