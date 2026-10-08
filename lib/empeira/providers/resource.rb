# frozen_string_literal: true

module Empeira
  module Providers
    class NotFound < Error; end
    class AlreadyExists < Error; end
    class OwnershipError < Error; end
    class ExecutionError < Error; end

    Resource = Data.define(:name, :owner, :state) do
      def initialize(name:, owner:, state:)
        unless [name, owner].all? { |value| value.is_a?(String) && !value.empty? }
          raise Error, 'Resource name and owner must be non-empty strings'
        end
        raise Error, 'Resource state must be running or stopped' unless %i[running stopped].include?(state)

        super(name: name.dup.freeze, owner: owner.dup.freeze, state: state)
      end
    end

    Result = Data.define(:resource, :changed) do
      def initialize(resource:, changed:)
        unless resource.nil? || resource.is_a?(Resource) || resource.is_a?(Network::Resource)
          raise Error, 'Result resource must be a resource or null'
        end
        raise Error, 'Result changed must be boolean' unless [true, false].include?(changed)

        super
      end
    end
  end
end
