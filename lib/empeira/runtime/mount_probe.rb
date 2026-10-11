# frozen_string_literal: true

module Empeira
  module Runtime
    # Prove that an engine sees this client's canonical directory, including VM-backed engines.
    class MountProbe
      def initialize(runtime:)
        @runtime = runtime
      end

      def verify(resource, mounts)
        mounts.each do |mount|
          fields = mount.split(',').select { |field| field.include?('=') }.to_h { |field| field.split('=', 2) }
          if File.file?(fields.fetch('src'))
            verify_file(resource, fields.fetch('src'), fields.fetch('dst'))
          else
            verify_directory(resource, fields.fetch('src'), fields.fetch('dst'))
          end
        end
      end

      private

      def verify_file(resource, source, destination)
        code = 'exit(File.file?(ARGV[0]) && File.readable?(ARGV[0]) ? 0 : 1)'
        result = @runtime.service_exec(resource, [ControlPlane::Health::RUBY, '-e', code, destination])
        return if result.success?

        failed_probe!(result, source, destination, 'Cannot verify the configured file mount (EYAML or server.mounts)')
      end

      def verify_directory(resource, source, destination)
        code = 'require "digest"; print Digest::SHA256.hexdigest(Dir.children(ARGV.fetch(0)).sort.join("\0"))'
        expected = Digest::SHA256.hexdigest(Dir.children(source).sort.join("\0"))
        result = @runtime.service_exec(resource, [ControlPlane::Health::RUBY, '-e', code, destination])
        return if result.success? && result.stdout == expected

        reason = if result.success?
                   'Container directory listing differs from the local mount source'
                 else
                   'Cannot execute the container directory mount probe'
                 end
        failed_probe!(result, source, destination, reason)
      rescue SystemCallError
        location = Execution::Diagnostics.safe_text(source.to_s)
        raise Error, "Cannot read local mount directory to verify the mount: #{location}", cause: nil
      end

      def failed_probe!(result, source, destination, reason)
        paths = Execution::Diagnostics.safe_text("Source: #{source}\nDestination: #{destination}")
        details = Execution::Diagnostics.command(result, operation: 'Verify server mount visibility',
                                                         tool: ControlPlane::Health::RUBY)
        raise Error, "#{reason}\n#{paths}\n#{details}", cause: nil
      end
    end
  end
end
