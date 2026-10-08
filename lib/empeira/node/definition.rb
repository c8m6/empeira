# frozen_string_literal: true

module Empeira
  module Node
    class Definition < Services::Definition
      attr_reader :hostname

      def initialize(hostname:, workspace:, **)
        @hostname = hostname
        super(key: "node-#{Digest::SHA256.hexdigest(hostname)[0, 24]}", workspace: workspace,
              hostname: hostname, **)
      end

      def ownership_labels
        super.merge('io.empeira.purpose' => 'node', 'io.empeira.hostname' => hostname,
                    'io.empeira.provider' => 'container')
      end
    end
  end
end
