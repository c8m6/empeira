# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class Allocation
        def initialize(context:, runtime:, runner:)
          @context = context
          @runtime = runtime
          @runner = runner
        end

        def choose
          occupied = @runtime.network_subnets + host_routes
          candidates.find { |candidate| occupied.none? { |route| overlap?(candidate, route) } } ||
            raise(Error, 'No safe private peer subnet is available; inspect host/VPN and runtime routes')
        end

        private

        def candidates
          offset = Digest::SHA256.hexdigest(@context.workspace.id)[0, 4].to_i(16)
          candidates = (0...256).map { |i| "10.#{160 + ((offset + i) % 64)}.#{(offset + i) % 256}.0/24" }
          candidates + alternatives(offset)
        end

        def alternatives(offset)
          (16..31).map { |i| "172.#{i}.#{offset % 256}.0/24" } +
            (0...256).map { |i| "192.168.#{(offset + i) % 256}.0/24" }
        end

        def overlap?(candidate, route)
          left, right = [candidate, route].map { |value| IPAddr.new(value) }
          left.include?(right.to_range.first) || right.include?(left.to_range.first)
        rescue IPAddr::InvalidAddressError
          raise Error, 'Cannot verify route overlap for the peer network', cause: nil
        end

        def host_routes
          Platform::Routes.new(platform: @context.platform, runner: @runner).ipv4
        end
      end
    end
  end
end
