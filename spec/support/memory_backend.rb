# frozen_string_literal: true

# Only adapter I/O is replaced: lifecycle semantics are exercised in production code.
module MemoryBackend
  def records
    @records ||= {}
  end

  def available?
    true
  end

  protected

  def lookup(name:)
    records[name]
  end

  def create(name:, request:) # rubocop:disable Lint/UnusedMethodArgument -- Shared adapter contract.
    records[name] = Empeira::Providers::Resource.new(name: name, owner: context.workspace.id, state: :running)
  end

  def transition(resource:, state:)
    records[resource.name] = resource.with(state: state)
  end

  def remove(resource:)
    records.delete(resource.name)
  end
end
