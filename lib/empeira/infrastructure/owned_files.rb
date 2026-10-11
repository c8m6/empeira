# frozen_string_literal: true

module Empeira
  module Infrastructure
    # Only private workspace descendants are removable; never traverse a symlink.
    module OwnedFiles
      def self.remove(path, root:, symlinks: false)
        return unless verify_removable!(path, root: root, symlinks: symlinks)

        FileUtils.remove_entry_secure(path)
      end

      def self.verify_removable!(path, root:, symlinks: false)
        verify_root!(root)
        candidate = Pathname(path)
        unless candidate.to_s.start_with?("#{root}/") && candidate.cleanpath == candidate
          raise Providers::OwnershipError, 'Cleanup path escapes its workspace'
        end
        return unless candidate.exist? || candidate.symlink?

        ancestors(candidate, root).each { |entry| verify_entry!(entry, directory: true) }
        verify_tree!(candidate, symlinks: symlinks)
        true
      end

      def self.verify_root!(root)
        verify_entry!(root, directory: true)
        raise Providers::OwnershipError, 'Workspace directory is not private' unless root.lstat.mode.nobits?(0o077)
      end

      def self.ancestors(path, root)
        entries = []
        current = path.dirname
        until current == root
          entries << current
          current = current.dirname
        end
        entries.reverse
      end

      def self.verify_tree!(path, symlinks: false)
        if symlinks && path.symlink?
          raise Providers::OwnershipError, 'Generated link ownership changed' unless path.lstat.uid == Process.uid

          return
        end
        verify_entry!(path)
        return unless path.directory?

        path.children.each { |child| verify_tree!(child, symlinks: symlinks) }
      end

      # rubocop:disable-next Metrics/CyclomaticComplexity -- File kind, link and owner checks form one fail-closed predicate.
      def self.verify_entry!(path, directory: false)
        metadata = path.lstat
        unless metadata.uid == Process.uid && !metadata.symlink? &&
               (!directory || metadata.directory?) && (metadata.file? || metadata.directory? || metadata.socket?)
          raise Providers::OwnershipError, 'Unsafe workspace path or ownership; cleanup refused'
        end
      end
    end
  end
end
