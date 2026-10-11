# frozen_string_literal: true

# Host receipt immediately before native agent exec, matching the previous SSH benchmark boundary.
class AgentEntryProbe
  MARKER = 'EMPEIRA_BENCHMARK_AGENT_ENTRY'

  def initialize
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @buffer = +''
  end

  attr_reader :seconds

  def <<(chunk)
    @buffer << chunk
    @seconds ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started if @buffer.include?(MARKER)
    @buffer = @buffer.byteslice(-128, 128) || @buffer
    self
  end

  def flush; end
end
