# frozen_string_literal: true

module Empeira
  module Modules
    class Request
      attr_reader :puppetfile, :data

      def initialize(context:)
        @context = context
        @project = context.project.path
        @config = context.configuration
        @hiera = Configuration::HieraMounts.new(config: @config.fetch('hiera'), project: @project,
                                                environment: @config.dig('server', 'environment'))
        @overrides = @hiera.entries.select { |entry| entry['type'] == 'module' && entry['status'] == 'available' }
                           .map { |entry| entry.fetch('name') }.sort
        load_file
      end

      def warnings
        @hiera.warnings
      end

      def present?
        !puppetfile.nil?
      end

      def verify_available!
        return unless present?

        root = Storage.new(context: @context).root
        return if State.new(context: @context).available?(root, overrides: data.fetch('overrides'))

        raise Error, "Puppetfile modules are not available.\nRun: empeira update modules"
      end

      private

      def load_file
        path = @project.join('Puppetfile')
        return unless path.exist? || path.symlink?
        raise ConfigurationError, 'Puppetfile must be a readable regular file inside the control repository' unless
          path.file? && path.realpath.to_s.start_with?("#{@project}/")

        verify_modulepath!
        validate_environment_mounts!
        @puppetfile = path.binread
        @data = { 'overrides' => @overrides }
      rescue SystemCallError
        raise ConfigurationError, 'Cannot read Puppetfile or control-repository modules', cause: nil
      end

      def verify_modulepath!
        environment = @config.dig('server', 'environment')
        Configuration::HieraModulepath.new(project: @project, environment: environment).verify!
      end

      def validate_environment_mounts!
        @hiera.entries.each_with_index do |entry, index|
          next unless entry['status'] == 'available' && entry['type'] == 'environment'
          next unless Configuration::HieraMountSchema.overlap?(entry.fetch('target'), 'modules')

          raise ConfigurationError,
                "hiera.mounts.#{index}.target overlaps Puppetfile modules; use type: module for local overrides"
        end
      end
    end
  end
end
