# frozen_string_literal: true

# rubocop:disable Lint/UnusedMethodArgument -- Preserve explicit adapter keyword contracts.

module Empeira
  module Providers
    # Adapters implement the protected operations. Public semantics stay shared.
    class Lifecycle
      attr_reader :name, :context, :runner

      def initialize(name:, context:, runner:)
        @name = name.dup.freeze
        @context = context
        @runner = runner
      end

      def available?
        false
      end

      def inspect_resource(name:)
        resource = lookup(name: name)
        return if resource.nil?

        verify_resource!(resource, name)
      end

      def run(name:, request:)
        raise AlreadyExists, 'Resource already exists' if inspect_resource(name: name)

        resource = verify_resource!(create(name: name, request: request), name)
        raise ExecutionError, 'Provider did not start the resource' unless resource.state == :running

        Result.new(resource: resource, changed: true)
      end

      def start(name:)
        change_state(name, :running)
      end

      def stop(name:)
        change_state(name, :stopped)
      end

      def destroy(name:)
        resource = inspect_resource(name: name)
        return Result.new(resource: nil, changed: false) unless resource

        remove(resource: resource)
        Result.new(resource: nil, changed: true)
      end

      protected

      def lookup(name:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end

      def create(name:, request:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end

      def transition(resource:, state:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end

      def remove(resource:)
        raise UnavailableFeature, 'This command is not implemented yet.'
      end

      private

      def verify_resource!(resource, expected_name)
        unless resource.is_a?(Resource) && resource.name == expected_name
          raise ExecutionError, 'Provider returned an invalid resource'
        end
        raise OwnershipError, 'Resource belongs to another workspace' unless resource.owner == context.workspace.id

        resource
      end

      def change_state(name, state)
        resource = inspect_resource(name: name)
        raise NotFound, 'Resource does not exist' unless resource
        return Result.new(resource: resource, changed: false) if resource.state == state

        updated = verify_resource!(transition(resource: resource, state: state), name)
        raise ExecutionError, 'Provider did not reach the requested state' unless updated.state == state

        Result.new(resource: updated, changed: true)
      end
    end
  end
end

# rubocop:enable Lint/UnusedMethodArgument
