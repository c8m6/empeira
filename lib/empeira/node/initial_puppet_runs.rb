# frozen_string_literal: true

module Empeira
  module Node
    # Only node creation uses this sequence; ordinary node puppet remains a single run.
    class InitialPuppetRuns
      def initialize(count:, progress:)
        @count = count
        @progress = progress
      end

      def run
        result = nil
        @count.times do |index|
          label = "#{index + 1}/#{@count}"
          @progress.heartbeat("Running Puppet agent (#{label})...")
          result = yield
          verify_completion!(result)
          report(result, label)
        end
        unless success?(result)
          raise Error, "Puppet agent failed (exit #{result.exit_status}); node retained for diagnostics and another run"
        end

        @progress.heartbeat('Node provisioning completed successfully.')
        result
      end

      private

      def report(result, label)
        message = "Puppet run #{label} finished with exit code #{result.exit_status}."
        success?(result) ? @progress.heartbeat(message) : @progress.warning(message)
      end

      def success?(result)
        [0, 2].include?(result.exit_status)
      end

      def verify_completion!(result)
        return if !result.timed_out && result.exit_status.is_a?(Integer) && result.exit_status.between?(0, 124)

        raise Error, 'Puppet process did not complete normally or could not start; node retained for diagnostics'
      end
    end
  end
end
