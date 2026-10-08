# frozen_string_literal: true

require 'digest'

module Empeira
  module Server
    # Hash live inputs, including untracked files and external mounts, without persisting their contents.
    class CodeSnapshot
      def initialize(plan:)
        @plan = plan
        @excluded = [plan.context.locations.state, plan.context.locations.cache].map(&:expand_path)
      end

      def fingerprint
        digest = Digest::SHA256.new
        sources.each do |path|
          digest << path.to_s << "\0"
          visit(path, digest, [])
        end
        digest.hexdigest
      rescue SystemCallError, IOError
        raise Error, 'Cannot read Puppet code inputs; environment cache refresh refused', cause: nil
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Resolve all configured mount sources in one place.
      def sources
        paths = [@plan.context.project.path]
        paths << Modules::Storage.new(context: @plan.context).root if paths.first.join('Puppetfile').file?
        paths.concat(@plan.hiera.entries.filter_map { |entry| entry['resolved_source'] })
        paths.concat(server_sources).map { |path| Pathname(path).expand_path }.uniq.sort
      end

      def server_sources
        @plan.project_server_mounts.map do |mount|
          mount.split(',').find { |part| part.start_with?('src=') }.delete_prefix('src=')
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Frame each tree entry unambiguously before hashing its contents.
      def visit(path, digest, ancestors)
        return if path.basename.to_s == '.git' || @excluded.include?(path)

        stat = path.stat
        digest << path.basename.to_s << "\0" << stat.ftype << "\0" << (stat.mode & 0o777).to_s << "\0"
        if stat.directory?
          directory(path, stat, digest, ancestors)
        elsif stat.file?
          digest << Digest::SHA256.file(path).hexdigest << "\0"
        else
          raise Error, 'Nonregular file in Puppet code inputs; environment cache refresh refused'
        end
        digest << "end\0"
      end

      def directory(path, stat, digest, ancestors)
        identity = [stat.dev, stat.ino]
        if ancestors.include?(identity)
          raise Error, 'Cyclic link in Puppet code inputs; environment cache refresh refused'
        end

        path.children.sort.each { |child| visit(child, digest, ancestors + [identity]) }
      end
    end
  end
end
