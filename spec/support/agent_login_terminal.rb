# frozen_string_literal: true

require 'stringio'

class AgentLoginTerminal < StringIO
  def tty?
    true
  end

  def noecho
    yield self
  end
end
