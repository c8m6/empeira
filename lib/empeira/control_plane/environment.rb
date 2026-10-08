# frozen_string_literal: true

module Empeira
  module ControlPlane
    # Mount destinations exist in state, while control code stays live and read-only.
    class Environment
      CONTROL = '/empeira-control'

      def initialize(context:, hiera:)
        @project = context.project.path
        @root = root(context)
        @targets = mount_targets(hiera)
        @modules = Modules::Storage.new(context: context).root if @project.join('Puppetfile').file?
        @targets |= ['modules'] if @modules
        @base = context.locations.workspace(context.workspace).join('environments')
        @directory = @base.join(Infrastructure::Definition.fingerprint([@targets, @modules&.to_s]))
      end

      def mounts
        return [bind(@project, @root)] if @targets.empty?

        [bind(@project, CONTROL), bind(@directory, @root),
         *(@modules ? [bind(@modules, "#{@root}/modules")] : [])]
      end

      def prepare
        return if @targets.empty?
        raise Error, 'Managed environment directory must not be a symlink' if @directory.symlink?

        FileUtils.mkdir_p(@directory, mode: 0o755)
        project_directory('', @directory)
      end

      def cleanup
        raise Error, 'Managed environment directory must not be a symlink' if @base.symlink?

        FileUtils.remove_entry_secure(@base) if @base.exist?
      end

      private

      def mount_targets(hiera)
        hiera.entries.select { |entry| entry['status'] == 'available' }.map do |entry|
          entry['destination'].delete_prefix("#{@root}/")
        end
      end

      def root(context)
        "/etc/puppetlabs/code/environments/#{context.configuration.dig('server', 'environment')}"
      end

      def bind(source, destination)
        "type=bind,src=#{source},dst=#{destination},readonly"
      end

      def project_directory(relative, destination)
        child_names(relative).each do |name|
          path = relative.empty? ? name : "#{relative}/#{name}"
          create_entry(path, destination.join(name))
        end
      end

      def child_names(relative)
        source = @project.join(relative)
        children = source.directory? ? source.children.map { |child| child.basename.to_s } : []
        children = [] if relative == 'modules' && @modules
        prefixes = target_prefixes(relative)
        children | prefixes
      end

      def target_prefixes(relative)
        @targets.filter_map do |target|
          next unless relative.empty? || target.start_with?("#{relative}/")

          target.delete_prefix(relative.empty? ? '' : "#{relative}/").split('/').first
        end
      end

      def create_link(relative, destination)
        File.symlink("#{CONTROL}/#{relative}", destination) unless destination.symlink? || destination.exist?
      end

      def create_entry(relative, destination)
        if @targets.any? { |target| target == relative || target.start_with?("#{relative}/") }
          create_target(relative, destination)
        else
          create_link(relative, destination)
        end
      end

      def create_target(relative, destination)
        raise Error, 'Managed environment destination is unsafe' if destination.symlink?

        FileUtils.mkdir_p(destination, mode: 0o755)
        return if @targets.include?(relative) && !(relative == 'modules' && @modules)

        project_directory(relative, destination)
      end
    end
  end
end
