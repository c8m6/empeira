# frozen_string_literal: true

require 'pathname'

module Empeira
  module Node
    # Validate external private-key paths without reading or copying their contents.
    class SSHIdentity
      def initialize(home:)
        @home = Pathname(home)
      end

      def resolve(value)
        path = path_for(value)
        stat = path.lstat
        raise ConfigurationError, 'SSH identity must be a readable regular file, without a symlink' unless
          stat.file? && path.readable?
        raise ConfigurationError, 'SSH identity permissions must exclude group and other access (use chmod 600)' unless
          stat.mode.nobits?(0o077)

        path.to_s
      rescue SystemCallError
        raise ConfigurationError, 'SSH identity is missing or unreadable', cause: nil
      end

      private

      def path_for(value)
        unless value.is_a?(String) && !value.empty? && !value.match?(/[\p{Cc}\p{Cf}]/)
          raise ConfigurationError, 'SSH identity must be a nonempty file path without control characters'
        end

        value.start_with?('~/') ? @home.join(value.delete_prefix('~/')).expand_path : Pathname(value).expand_path
      end
    end
  end
end
