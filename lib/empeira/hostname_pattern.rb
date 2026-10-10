# frozen_string_literal: true

module Empeira
  # Full-hostname glob semantics shared by independent hostname policies.
  module HostnamePattern
    def self.valid?(value)
      value.is_a?(String) && value.size.between?(1, 253) && value.match?(/\A[a-z0-9*?][a-z0-9.*?-]*\z/i)
    end

    def self.matches?(pattern, hostname)
      File.fnmatch?(pattern.downcase, hostname.downcase)
    end
  end
end
