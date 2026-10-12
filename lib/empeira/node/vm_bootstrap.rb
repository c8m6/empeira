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

      # rubocop:disable-next Naming/PredicateMethod, Metrics/AbcSize -- Verify, atomically upload and verify the owned fact.
      def reconcile(record:, bootstrap:)
        bootstrap.files.map do |file|
          content = @guest.run(record, ['cat', file.path])
          mode = @guest.run(record, ['stat', '-c', '%a', file.path])
          next false if valid_file?(content, mode, file)

          Tempfile.create('empeira-fact') do |source|
            source.write(file.content)
            source.flush
            @guest.copy_to(record, source.path, file.path, mode: format('%04o', file.mode))
          end
          verify_file!(record, file)
          true
        end.any?
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
