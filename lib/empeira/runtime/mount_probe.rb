# frozen_string_literal: true

require 'digest'
require 'json'

module Empeira
  module Runtime
    # Verify all canonical mount sources through one guest process.
    class MountProbe
      PROBE = <<~'RUBY'
        require 'digest'
        require 'json'
        JSON.parse(ARGV.fetch(0)).each do |mount|
          path = mount.fetch('destination')
          valid = if mount.key?('listing')
                    Digest::SHA256.hexdigest(Dir.children(path).sort.join("\0")) == mount.fetch('listing')
                  else
                    File.file?(path) && File.readable?(path)
                  end
          abort "Mount destination is unreadable or its directory listing differs: #{path}" unless valid
        end
      RUBY

      def initialize(runtime:)
        @runtime = runtime
      end

      def verify(resource, mounts)
        return if mounts.empty?

        fields = mount_fields(mounts)
        checks = fields.map { |mount| check(mount) }
        result = @runtime.service_exec(resource, [ControlPlane::Health::RUBY, '-e', PROBE, JSON.generate(checks)])
        return if result.success?

        failed_probe!(result, fields)
      end

      private

      def mount_fields(mounts)
        mounts.uniq.map do |mount|
          mount.split(',').select { |field| field.include?('=') }.to_h { |field| field.split('=', 2) }
        end
      end

      def failed_probe!(result, fields)
        paths = fields.map { |mount| "Source: #{mount.fetch('src')}\nDestination: #{mount.fetch('dst')}" }.join("\n")
        details = Execution::Diagnostics.command(result, operation: 'Verify server mount visibility',
                                                         tool: ControlPlane::Health::RUBY)
        raise Error, "Cannot verify configured server mounts\n#{Execution::Diagnostics.safe_text(paths)}\n#{details}"
      end

      def check(mount)
        source = mount.fetch('src')
        result = { 'destination' => mount.fetch('dst') }
        result['listing'] = Digest::SHA256.hexdigest(Dir.children(source).sort.join("\0")) unless File.file?(source)
        result
      rescue SystemCallError
        location = Execution::Diagnostics.safe_text(source.to_s)
        raise Error, "Cannot read local mount directory to verify the mount: #{location}", cause: nil
      end
    end
  end
end
