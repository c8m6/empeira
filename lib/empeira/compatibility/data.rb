# frozen_string_literal: true

# Ruby 3.2 introduced immutable Data value objects. Keep Ruby 3.1 support
# without replacing the native Data implementation on newer Rubies.
module Empeira
  module Compatibility
    module DataFactory
      module_function

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Ruby 3.1 must emulate Data initializer semantics.
      def define(*members, &definition)
        # The explicit nil class name also permits zero members and preserves
        # Struct's value equality, hashing and pattern matching for empty records.
        base_class = Struct.new(nil, *members, keyword_init: true)
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

          def initialize_copy(other)
            super
            freeze
          end
        end
        value_class = Class.new(base_class)
        define_constructors(value_class)
        value_class.include(self)
        value_class.class_eval(&definition) if definition
        value_class
      end

      # rubocop:disable-next Metrics/AbcSize -- Normalize native Data constructors before custom initialization.
      def define_constructors(value_class)
        value_class.define_singleton_method(:new) do |*positional, **keywords|
          raise ArgumentError, 'cannot mix positional and keyword arguments' unless positional.empty? || keywords.empty?
          raise ArgumentError, 'too many positional arguments' if positional.size > members.size

          keywords = members.take(positional.size).zip(positional).to_h unless positional.empty?
          super(**keywords).freeze
        end
        value_class.define_singleton_method(:[]) { |*positional, **keywords| new(*positional, **keywords) }
      end
    end
  end
end

Data = Empeira::Compatibility::DataFactory unless defined?(Data)
