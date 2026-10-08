# frozen_string_literal: true

module Empeira
  class Progress
    Event = Data.define(:percent, :message, :state)

    def initialize(listener: nil)
      @listener = listener
      @percent = 0
      @message = ''
    end

    def run(message)
      @active = true
      @percent = 0
      emit(message, :active)
      result = yield
      @percent = 100
      emit('Completed.', :complete)
      result
    rescue StandardError, Interrupt
      emit("Failed: #{@message}", :failed)
      raise
    ensure
      @active = false
    end

    def stage(percent, message)
      return unless @active

      raise ArgumentError, 'Progress stages must increase and remain below 100' unless percent.between?(@percent, 99)

      @percent = percent
      emit(message, :active)
    end

    def heartbeat(message = @message)
      emit(message, :active) if @active && !@streaming
    end

    def count(completed, total, message)
      return unless @active
      raise ArgumentError, 'Invalid progress counts' unless completed.between?(0, total)

      @percent = completed == total ? 100 : [(100.0 * completed / total).round, 99].min
      emit(message, :active)
    end

    def warning(message)
      @listener&.call(Event.new(percent: @percent, message: message, state: :warning))
    end

    def streaming
      @streaming = true
      emit(@message, :suspended) if @active
      result = yield
      emit(@message, :resumed) if @active
      result
    ensure
      @streaming = false
    end

    private

    def emit(message, state)
      @message = message
      @listener&.call(Event.new(percent: @percent, message: message, state: state))
    end
  end
end
