# frozen_string_literal: true

require 'pathname'

module Empeira
  module Node
    # Restore native DNF repository configuration after the temporary agent source.
    class RpmConfiguration
      DISTRIBUTIONS = %w[rocky almalinux oraclelinux rhel].freeze
      BACKUP = '/root/.empeira-dnf-before-bootstrap.tar'

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
        execute!(['install', '--mode', '0600', '/dev/null', @backup.to_s], 'Cannot prepare DNF configuration backup')
        execute!(['tar', '--create', '--file', @backup.to_s, '--directory', @root.to_s,
                  'etc/yum.repos.d', 'etc/dnf'],
                 'Cannot preserve base image DNF configuration')
      rescue StandardError
        @execute.call(['rm', '--force', '--', @backup.to_s])
        raise
      end

      def restore!
        message = 'Cannot restore and verify base image DNF configuration; ' \
                  'Puppet was not run. Node retained for diagnosis'
        execute!(['tar', '--list', '--file', @backup.to_s], message)
        execute!(['rm', '--recursive', '--force', '--', @root.join('etc/yum.repos.d').to_s,
                  @root.join('etc/dnf').to_s], message)
        execute!(['tar', '--extract', '--file', @backup.to_s, '--directory', @root.to_s], message)
        execute!(['tar', '--compare', '--file', @backup.to_s, '--directory', @root.to_s], message)
        execute!(['rm', '--force', '--', @backup.to_s], message)
      end

      def execute!(arguments, message)
        raise Error, message unless @execute.call(arguments).success?
      end
    end
  end
end
