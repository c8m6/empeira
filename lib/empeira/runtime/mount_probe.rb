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
            verify_file(resource, fields.fetch('dst'))
          else
            verify_directory(resource, fields.fetch('src'), fields.fetch('dst'))
          end
        end
      end

      private

      def verify_file(resource, destination)
        code = 'exit(File.file?(ARGV[0]) && File.readable?(ARGV[0]) ? 0 : 1)'
        result = @runtime.service_exec(resource, [ControlPlane::Health::RUBY, '-e', code, destination])
        return if result.success?

        raise Error, 'Container engine cannot read the configured file mount (EYAML or server.mounts)'
      end

      def verify_directory(resource, source, destination)
        code = 'require "digest"; print Digest::SHA256.hexdigest(Dir.children(ARGV.fetch(0)).sort.join("\0"))'
        expected = Digest::SHA256.hexdigest(Dir.children(source).sort.join("\0"))
        result = @runtime.service_exec(resource, [ControlPlane::Health::RUBY, '-e', code, destination])
        return if result.success? && result.stdout == expected

        raise Error,
              'Container engine cannot read the local control/Hiera/server directory. Configure shared paths first.'
      rescue SystemCallError
        raise Error, 'Cannot read local control/Hiera/server mount directory to verify the mount', cause: nil
      end
    end
  end
end
