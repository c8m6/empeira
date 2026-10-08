# frozen_string_literal: true

module Empeira
  module Configuration
    class HieraModulepath
      def initialize(project:, environment:)
        @project = project
        @environment = environment
      end

      def verify!
        value = configured_path
        return unless value
        return if value.strip.split(':').any? { |path| included_or_unknown?(path) }

        raise ConfigurationError,
              'hiera.mounts/Puppetfile module destinations are excluded by environment.conf modulepath; ' \
              'include modules in the environment modulepath'
      rescue SystemCallError
        raise ConfigurationError, 'Cannot read environment.conf to verify the modulepath', cause: nil
      end

      private

      def configured_path
        file = @project.join('environment.conf')
        return unless file.exist?

        file.read.lines.filter_map { |line| line.match(/^\s*modulepath\s*=\s*([^#]*)/)&.captures&.first }.last
      end

      def included_or_unknown?(path)
        path = path.gsub('$codedir', '/etc/puppetlabs/code').gsub('$environment', @environment)
        relative = Pathname(path).cleanpath.to_s
        relative == 'modules' || relative == "/etc/puppetlabs/code/environments/#{@environment}/modules" ||
          (path.include?('$') && path != '$basemodulepath')
      end
    end
  end
end
