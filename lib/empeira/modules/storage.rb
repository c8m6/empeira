# frozen_string_literal: true

module Empeira
  module Modules
    # The configured path is the module directory itself, never a deployment cache.
    class Storage
      attr_reader :root

      def initialize(context:)
        project = context.project.path
        @root = GitSafety.canonical_path(Pathname(context.configuration.dig('modules', 'path')).expand_path(project))
        validate_root!(project)
      end

      def prepare
        raise Error, 'modules.path must be a directory' if root.exist? && !root.directory?

        FileUtils.mkdir_p(root)
      rescue SystemCallError
        raise Error, 'Cannot create the configured module directory', cause: nil
      end

      private

      def validate_root!(project)
        git = project.join('.git')
        return unless root == project || project.to_s.start_with?("#{root}/") || root == root.parent ||
                      root == git || root.to_s.start_with?("#{git}/")

        raise ConfigurationError,
              'modules.path must not contain the control repository, a filesystem root or Git metadata'
      end
    end
  end
end
