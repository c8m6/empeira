# frozen_string_literal: true

module Empeira
  module ControlPlane
    # Generated data stays outside service-wide directory mounts and control code.
    class AdditionalConfigurations
      attr_reader :directory

      def initialize(context:)
        @context = context
        @workspace = context.locations.workspace(context.workspace)
        @directory = @workspace.join('additional-configurations')
      end

      def path(entry)
        directory.join("#{Digest::SHA256.hexdigest(entry.fetch('name'))}.yaml")
      end

      def options(entry, location:, mounts: [])
        return {} unless entry.key?('configuration')

        value = entry.fetch('configuration')
        targets = mounts.map do |mount|
          mount.split(',').find do |part|
            part.start_with?('dst=')
          end.to_s.delete_prefix('dst=')
        end
        Configuration::ServiceConfiguration.validate_targets!(value.fetch('target'), targets, location)
        content = Configuration::ServiceConfiguration.serialize(value.fetch('content'), location)
        { configuration: content,
          mounts: [*mounts, "type=bind,src=#{path(entry)},dst=#{value.fetch('target')},readonly"] }
      end

      def prepare
        return if entries.empty?

        verify_directory!
        FileUtils.mkdir_p(directory, mode: 0o700)
        entries.each { |entry| write(entry) }
      end

      def prune
        return unless directory.exist? || directory.symlink?

        verify_directory!

        expected = entries.map { |entry| path(entry) }
        directory.children.each { |file| File.unlink(file) unless expected.include?(file) }
      end

      def cleanup
        return unless directory.exist? || directory.symlink?

        verify_directory!
        FileUtils.remove_entry_secure(directory) if directory.exist?
      end

      private

      def entries
        @context.configuration.dig('containers', 'additional').select { |entry| entry.key?('configuration') }
      end

      def verify_directory!
        state = @context.locations.state
        [state, @workspace.parent, @workspace, directory].each do |parent|
          raise Error, 'Additional configuration directory must not be a symlink' if parent.symlink?
        end
        verify_external!
        raise Error, 'Additional configuration mount source is unsafe' if directory.to_s.match?(/[,\r\n]/)
      end

      def verify_external!
        ancestor = directory
        ancestor = ancestor.parent until ancestor.exist?
        project = @context.project.path.to_s
        return unless ancestor.realpath.to_s == project || ancestor.realpath.to_s.start_with?("#{project}/")

        raise Error, 'Additional configuration files must be outside the control repository'
      end

      def write(entry)
        destination = path(entry)
        if destination.symlink? || (destination.exist? && !destination.file?)
          raise Error, 'Additional configuration file must be a regular file, not a symlink'
        end

        content = Configuration::ServiceConfiguration.serialize(entry.dig('configuration', 'content'), 'configuration')
        return if destination.file? && destination.binread == content

        atomic_write(destination, content)
      end

      def atomic_write(destination, content)
        Tempfile.create('configuration-', directory) do |file|
          # The private workspace protects host access; arbitrary container UIDs need read access.
          file.chmod(0o644)
          file.write(content)
          file.flush
          file.fsync
          File.rename(file.path, destination)
        end
      end
    end
  end
end
