# frozen_string_literal: true

module Empeira
  module Modules
    class GitSafety
      def initialize(project:, runner:, progress: Progress.new)
        @project = project
        @runner = runner
        @progress = progress
      end

      def verify(path, recommend: false)
        relative = relative_path(path)
        return unless relative
        raise Error, 'The managed module path cannot be the control-repository root' if relative == '.'

        tracked = git('ls-files', '--cached', '-z', '--', ":(literal)#{relative}")
        raise Error, 'Cannot verify Git-tracked contents of the managed module path' unless tracked.success?
        unless tracked.stdout.empty?
          raise Error,
                'The managed module path contains Git-tracked files; refusing to modify it'
        end

        recommend_ignore(relative) if recommend
      end

      def self.canonical_path(path)
        return path.realpath if path.exist? || path.symlink?

        canonical_path(path.parent).join(path.basename)
      rescue SystemCallError
        raise Error, 'Cannot resolve the managed module path for Git safety checks', cause: nil
      end

      private

      def relative_path(path)
        canonical = self.class.canonical_path(path.expand_path)
        return unless canonical == @project || canonical.to_s.start_with?("#{@project}/")

        canonical.relative_path_from(@project).to_s
      end

      def recommend_ignore(relative)
        ignored = git('check-ignore', '--quiet', '--', "#{relative}/")
        return if ignored.success? || @recommended
        unless ignored.exit_status == 1 && !ignored.timed_out
          raise Error, 'Cannot determine whether Git ignores the managed module path'
        end

        @progress.warning("Recommendation: #{relative}/ is not ignored by Git. Add /#{relative}/ to .gitignore.")
        @recommended = true
      end

      def git(*arguments)
        @runner.run('git', arguments: arguments, directory: @project, timeout: 15)
      end
    end
  end
end
