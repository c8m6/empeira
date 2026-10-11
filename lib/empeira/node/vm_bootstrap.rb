# frozen_string_literal: true

module Empeira
  module Node
    # Cloud-Init installs shared files; management transport verifies them before Puppet.
    class VMBootstrap
      def initialize(guest:)
        @guest = guest
      end

      def verify(record:, bootstrap:)
        bootstrap.files.each { |file| verify_file!(record, file) }
      end

      private

      def verify_file!(record, file)
        content = @guest.run(record, ['cat', file.path])
        mode = @guest.run(record, ['stat', '-c', '%a', file.path])
        return if valid_file?(content, mode, file)

        details = [file_diagnostic(content, file, 'content', 'cat'), file_diagnostic(mode, file, 'mode', 'stat')]
        raise Error, "Cannot verify required Empeira VM bootstrap file #{file.path}; Puppet was not run\n" \
                     "#{details.join("\n")}", cause: nil
      end

      def file_diagnostic(result, file, field, tool)
        Execution::Diagnostics.command(result, operation: "Bootstrap file #{file.path}: #{field}", tool: tool)
      end

      def valid_file?(content, mode, file)
        content.success? && content.stdout == file.content && mode.success? && mode.stdout.strip.to_i(8) == file.mode
      end
    end
  end
end
