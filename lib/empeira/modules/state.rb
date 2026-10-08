# frozen_string_literal: true

module Empeira
  module Modules
    # Native tooling caches and a small optional list of installed names, never input/tree fingerprints.
    class State
      attr_reader :sources, :cache

      def initialize(context:)
        @workspace = context.workspace.id
        @directory = context.locations.workspace(context.workspace)
        @path = @directory.join('module-sync.json')
        @sources = @directory.join('r10k', 'sources')
        @cache = @directory.join('r10k', 'cache')
      end

      def available?(root, overrides: [])
        return false unless root.directory?

        names = installed_names(root)
        !names.nil? && names.all? { |name| overrides.include?(name) || populated?(root.join(name)) }
      rescue SystemCallError, JSON::ParserError
        raise Error, 'Cannot read module synchronization metadata', cause: nil
      end

      def prepare
        [sources.parent, sources, cache].each do |path|
          raise Error, 'r10k cache directories must not be symlinks' if path.symlink?

          FileUtils.mkdir_p(path, mode: 0o700)
        end
      end

      def invalidate
        raise Error, 'Module synchronization metadata must not be a symlink' if @path.symlink?

        @path.unlink if @path.exist?
      end

      def record(root, names)
        data = { 'version' => 1, 'workspace' => @workspace, 'path' => root.to_s, 'names' => names }
        Tempfile.create(['module-sync-', '.json'], @directory) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(data))
          file.flush
          File.rename(file.path, @path)
        end
      end

      private

      def installed_names(root)
        raise Error, 'Module synchronization metadata must not be a symlink' if @path.symlink?

        data = read if @path.exist?
        data && data['path'] == root.to_s ? data['names'] : existing_names(root)
      end

      def read
        data = JSON.parse(@path.read)
        raise Error, 'Invalid module synchronization metadata; inspect the workspace state' unless valid?(data)

        data
      end

      def valid?(data)
        data.is_a?(Hash) && data['workspace'] == @workspace && data['version'] == 1 &&
          data['path'].is_a?(String) && valid_names?(data['names'])
      end

      def valid_names?(names)
        names.is_a?(Array) && names.all? { |name| name.is_a?(String) && name.match?(Configuration::HieraMountSchema::NAME) }
      end

      def existing_names(root)
        names = root.children.filter_map do |path|
          path.basename.to_s if populated?(path) && path.basename.to_s.match?(Configuration::HieraMountSchema::NAME)
        end
        names unless names.empty?
      end

      def populated?(path)
        path.directory? && !path.symlink? && !path.children.empty?
      end
    end
  end
end
