# frozen_string_literal: true

module Empeira
  module Platform
    class Routes
      def initialize(platform:, runner:)
        @platform = platform
        @runner = runner
      end

      def ipv4
        return linux_routes if @platform.os != :macos

        mac_routes
      end

      private

      def mac_routes
        result = @runner.run('netstat', arguments: %w[-rn -f inet], timeout: 10)
        raise Error, 'Cannot inspect host IPv4 routes before allocating the peer network' unless result.success?

        result.stdout.lines.filter_map do |line|
          destination = line.split.first
          next unless destination&.match?(/\A\d/)

          expand_destination(destination)
        end
      end

      def expand_destination(destination)
        address, prefix = destination.split('/')
        octets = address.split('.')
        "#{(octets + (['0'] * (4 - octets.size))).join('.')}/#{prefix || (octets.size * 8)}"
      end

      def linux_routes
        result = @runner.run('ip', arguments: %w[-j -4 route show table all], timeout: 10)
        raise Error, 'iproute2 is required to verify host routes before peer subnet allocation' unless result.success?

        JSON.parse(result.stdout).filter_map do |route|
          destination = route.fetch('dst')
          destination unless %w[default 0.0.0.0/0].include?(destination)
        end
      rescue JSON::ParserError, KeyError
        raise Error, 'Cannot verify host IPv4 route inventory', cause: nil
      end
    end
  end
end
