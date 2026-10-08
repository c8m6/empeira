# frozen_string_literal: true

module Empeira
  module Node
    # Preserve the base image's complete APT configuration around temporary
    # agent-repository and package-bootstrap changes.
    class AptConfiguration
      DISTRIBUTIONS = %w[ubuntu debian].freeze
      BACKUP = '/root/.empeira-apt-before-bootstrap.tar'

      def initialize(os:, execute:, root: '/', backup: BACKUP)
        @os = os
        @execute = execute
        @root = Pathname(root).cleanpath
        @backup = Pathname(backup).cleanpath
      end

      def preserve
        return yield unless DISTRIBUTIONS.include?(@os)

        capture!
        begin
          yield
        ensure
          restore!
        end
      end

      private

      def capture!
        execute!(['install', '--mode', '0600', '/dev/null', @backup.to_s], 'Cannot prepare APT configuration backup')
        execute!(['tar', '--create', '--file', @backup.to_s, '--directory', @root.to_s, 'etc/apt'],
                 'Cannot preserve the base image APT configuration')
      rescue StandardError
        @execute.call(['rm', '--force', '--', @backup.to_s])
        raise
      end

      def restore!
        execute!(['tar', '--list', '--file', @backup.to_s], restore_error)
        execute!(['rm', '--recursive', '--force', '--', @root.join('etc/apt').to_s], restore_error)
        execute!(['tar', '--extract', '--file', @backup.to_s, '--directory', @root.to_s], restore_error)
        execute!(['tar', '--compare', '--file', @backup.to_s, '--directory', @root.to_s], restore_error)
        execute!(['rm', '--force', '--', @backup.to_s],
                 'Cannot remove the restored APT configuration backup; Puppet was not run. Node retained for diagnosis')
      end

      def restore_error
        'Cannot restore and verify the base image APT configuration; Puppet was not run. Node retained for diagnosis'
      end

      def execute!(arguments, message)
        result = @execute.call(arguments)
        return if result.success?

        raise Error, message
      end
    end
  end
end
