# frozen_string_literal: true

require 'rubygems/requirement'
require 'rubygems/version'

module Empeira
  class VersionRequirement
    def self.parse(value)
      return if value.nil?

      raise ArgumentError unless valid?(value)

      Gem::Requirement.new(*value.split(',').map(&:strip))
    rescue ArgumentError
      raise ConfigurationError, 'requirements.empeira must be a RubyGems version requirement or null', cause: nil
    end

    def self.valid?(value)
      value.is_a?(String) && !value.strip.empty? && value.split(',', -1).none? { |part| part.strip.empty? }
    end
    private_class_method :valid?
  end
end
