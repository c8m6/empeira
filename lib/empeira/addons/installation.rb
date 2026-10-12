# frozen_string_literal: true

module Empeira
  module Addons
    class Installation
      attr_reader :name, :source, :ref

      def initialize(name:, definition:, context:, runner:)
        @name = name
        @source, @ref = definition.values_at('git', 'ref')
        @runner = runner
        @project = context.project.path
        @storage = Storage.new(base: cache_root(context), source: source, ref: ref)
      rescue Empeira::Error, SystemCallError => e
        failure(e)
      end

      def local
        record = @storage.installed
        return unless record

        commit, path = record
        [commit, path, Manifest.new(name: name, path: path)]
      rescue Empeira::Error, SystemCallError => e
        failure(e)
      end

      def synchronize(missing_only: false)
        return local if missing_only && local

        @storage.synchronize do
          return local if missing_only && local

          acquire
          commit = resolve
          materialize(commit)
          @storage.publish(commit)
          local
        end
      rescue Empeira::Error, SystemCallError => e
        failure(e)
      end

      private

      def cache_root(context)
        root = Modules::GitSafety.canonical_path(context.locations.addons)
        if root == @project || root.to_s.start_with?("#{@project}/")
          raise Error.new(name, 'user addon cache must be outside the control repository')
        end

        root
      end

      def failure(error)
        raise error if error.is_a?(Error)

        message = error.is_a?(SystemCallError) ? 'cache is inaccessible or installation is incomplete' : error.message
        raise Error.new(name, message), cause: nil
      end

      def acquire
        git = Modules::HostGit.new(runner: @runner, project: @project, passive: true)
        entries = [{ 'name' => 'addon', 'remote' => source }]
        return git.prepare(entries, directory: @storage.root) if @storage.mirror.exist?

        @storage.stage do |directory|
          mirror = git.prepare(entries, directory: directory).fetch('addon')
          File.rename(mirror, @storage.mirror)
        end
      end

      def resolve
        result = git('rev-parse', '--verify', '--end-of-options', "#{ref}^{commit}")
        commit = result.stdout.strip
        unless result.success? && commit.match?(Storage::COMMIT)
          raise Error.new(name, 'Git reference is unknown or does not resolve to a commit'), cause: nil
        end

        commit
      end

      def materialize(commit)
        final = @storage.revision(commit)
        return Manifest.new(name: name, path: final) if final.exist?

        @storage.stage do |directory|
          checkout(commit, directory)
          Manifest.new(name: name, path: directory)
          File.rename(directory, final)
        end
      end

      def checkout(commit, directory)
        Tempfile.create('.index-', @storage.root) do |index|
          File.unlink(index.path)
          environment = { 'GIT_INDEX_FILE' => index.path }
          tree = git('read-tree', commit, environment: environment)
          raise Error.new(name, 'Git could not read the resolved commit') unless tree.success?

          files = git('--work-tree', directory.to_s, 'checkout-index', '--all', "--prefix=#{directory}/",
                      environment: environment)
          raise Error.new(name, 'Git could not materialize the resolved commit') unless files.success?
        end
      end

      def git(*arguments, environment: {})
        # Authentication happens only in HostGit. Local export must not run
        # user-configured smudge filters from .gitattributes or hooks.
        environment = { 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1',
                        'GIT_CONFIG_COUNT' => '0', 'GIT_CONFIG_PARAMETERS' => nil, 'GIT_ATTR_NOSYSTEM' => '1' }
                      .merge(environment)
        @runner.run('git', arguments: ['-c', "core.hooksPath=#{File::NULL}", '-c', 'core.fsmonitor=false',
                                       '--git-dir', @storage.mirror.to_s, *arguments],
                           environment: environment, directory: @project, timeout: 300)
      end
    end
  end
end
