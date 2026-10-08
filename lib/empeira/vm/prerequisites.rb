# frozen_string_literal: true

module Empeira
  module VM
    class Prerequisites
      def initialize(engine:, platform:)
        @engine = engine
        @platform = platform
      end

      def verify!(progress: Progress.new, seeds: true)
        progress.stage(5, 'Checking VM host prerequisites...')
        results = @engine.required_tools(seeds: seeds).to_h do |tool|
          [tool, @engine.find(tool) ? 'available' : 'missing']
        end
        progress.stage(10, 'Checking hardware acceleration and firmware...')
        accelerator = check(results, 'Accelerator') { @engine.accelerator }
        check(results, 'ARM64 firmware') { @engine.firmware || 'not required' }
        return accelerator if results.values.all? { |value| value == 'available' }

        raise UnavailableFeature, failure_report(results)
      end

      private

      def failure_report(results)
        report = results.map { |name, status| "  #{name.ljust(23)} #{status}" }.join("\n")
        "VM prerequisites are not satisfied (#{@platform.os}/#{@platform.architecture}):\n\n" \
          "#{report}\n\n#{@platform.vm_install_hint}"
      end

      def check(results, name)
        value = yield
        results[name] = 'available'
        value
      rescue Error => e
        results[name] = e.message
        nil
      end
    end
  end
end
