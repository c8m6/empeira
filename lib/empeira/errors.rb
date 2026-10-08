# frozen_string_literal: true

module Empeira
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ExecutionError < Error; end
  class UnsupportedPlatform < Error; end
  class UnavailableFeature < Error; end
end
