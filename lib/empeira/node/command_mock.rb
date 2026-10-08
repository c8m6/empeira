# frozen_string_literal: true

require 'shellwords'

module Empeira
  module Node
    # A guest file resource with the same ownership labels and fingerprint contract as services.
    class CommandMock < Services::Definition
      attr_reader :command

      def initialize(command:, workspace:, record:, definition:)
        @command = command
        super(key: "command-mock-#{command}", workspace: workspace, **definition.transform_keys(&:to_sym),
              hostname: record.fetch('hostname'), provider: record.fetch('provider'))
      end

      def ownership_labels
        super.merge('io.empeira.hostname' => options.fetch('hostname'),
                    'io.empeira.provider' => options.fetch('provider'))
      end

      def file
        Bootstrap::FileEntry.new(path: options.fetch('path'), content: content, mode: 0o755).freeze
      end

      def content
        invocation = if options.fetch('mock_to') == 'echo'
                       "printf '%s' #{Shellwords.escape(command)}\n" \
                         "[ \"$#\" -eq 0 ] || printf ' %s' \"$@\"\nprintf '\\n'\n"
                     else
                       "#{Shellwords.escape(options.fetch('mock_to'))} \"$@\"\n"
                     end
        status = options.fetch('exit_code') == 'passthrough' ? '$?' : options.fetch('exit_code').to_s
        "#!/bin/sh\n# #{JSON.generate(labels)}\n#{invocation}exit #{status}\n"
      end
    end
  end
end
