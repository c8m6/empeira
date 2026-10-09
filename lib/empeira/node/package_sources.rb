# frozen_string_literal: true

module Empeira
  module Node
    module PackageSources
      def self.verify!(execute:)
        script = Pathname(__dir__).join('../../../resources/nodes/apt_sources.rb').read
        result = execute.call([Certificates::RUBY, '-e', script])
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Active distribution APT source verification',
                                                         tool: 'ruby')
        raise Error, 'Cannot verify an active Ubuntu/Debian distribution APT source before the first catalog. ' \
                     'Check /etc/apt/sources.list and sources.list.d/*.list or *.sources in the image/bootstrap; ' \
                     "Puppet was not run. Node retained for diagnosis.\n#{details}", cause: nil
      end
    end
  end
end
