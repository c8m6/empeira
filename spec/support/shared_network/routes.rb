# frozen_string_literal: true

require 'ipaddr'

module SharedNetworkProof
  module Routes
    def self.reject_overlap!(routes, subnet)
      candidate = IPAddr.new(subnet)
      overlap = routes.any? do |route|
        next false if route.fetch('dst') == 'default'

        existing = IPAddr.new(route.fetch('dst'))
        existing.include?(candidate) || candidate.include?(existing)
      end
      return unless overlap

      raise Failure, "Proof subnet #{subnet} overlaps an existing route; no network was adopted"
    end
  end
end
