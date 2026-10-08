# frozen_string_literal: true

module Empeira
  module Node
    # The complete Empeira-owned guest file state required before the first catalog.
    class Bootstrap
      FileEntry = Struct.new(:path, :content, :mode, keyword_init: true)

      attr_reader :files

      def initialize(provider:)
        @files = [FileEntry.new(path: ExternalFact::PATH, content: ExternalFact.content(provider),
                                mode: 0o644).freeze].freeze
      end
    end
  end
end
