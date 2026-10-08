# frozen_string_literal: true

module Empeira
  module Node
    # Cloud-Init installs shared files; management SSH verifies them before Puppet.
    class VMBootstrap
      def initialize(ssh:)
        @ssh = ssh
      end

      def verify(record:, bootstrap:)
        bootstrap.files.each do |file|
          next if valid_file?(record, file)

          raise Error, "Cannot verify required Empeira VM bootstrap file #{file.path}; Puppet was not run"
        end
      end

      private

      def valid_file?(record, file)
        content = @ssh.run(record, ['cat', file.path])
        mode = @ssh.run(record, ['stat', '-c', '%a', file.path])
        content.success? && content.stdout == file.content && mode.success? && mode.stdout.strip.to_i(8) == file.mode
      end
    end
  end
end
