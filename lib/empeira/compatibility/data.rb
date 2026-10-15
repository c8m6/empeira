# frozen_string_literal: true

# Ruby 3.2 introduced immutable Data value objects. Keep Ruby 3.1 support
# without replacing the native Data implementation on newer Rubies.
module Empeira
  module Compatibility
    module DataFactory
      module_function

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- Ruby 3.1 must emulate Data initializer semantics.
      def define(*members, &definition)
        base_class = if members.empty?
                       Class.new do
                         def self.members
                           []
                         end

                         def to_h
                           {}
                         end
                       end
                     else
                       Struct.new(*members, keyword_init: true)
                     end
        base_class.class_eval do
          def initialize(*positional, **keywords)
            fields = self.class.members
            raise ArgumentError, 'too many positional arguments' if positional.size > fields.size

            supplied = fields.take(positional.size).zip(positional).to_h.merge(keywords)
            missing = fields - supplied.keys
            unexpected = supplied.keys - fields
            raise ArgumentError, "missing keywords: #{missing.join(', ')}" unless missing.empty?
            raise ArgumentError, "unknown keywords: #{unexpected.join(', ')}" unless unexpected.empty?

            super(**supplied)
            freeze
          end

          def with(**changes)
            self.class.new(**to_h, **changes)
          end
        end
        value_class = Class.new(base_class)
        value_class.include(self)
        value_class.class_eval(&definition) if definition
        value_class
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
  end
end

Data = Empeira::Compatibility::DataFactory unless defined?(Data)
