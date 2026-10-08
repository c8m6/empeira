# frozen_string_literal: true

require 'digest'
require 'json'

module Empeira
  module Infrastructure
    class Definition
      REVISION = 2
      attr_reader :network, :metadata, :plan

      def self.fingerprint(data)
        Digest::SHA256.hexdigest(JSON.generate(canonical(data)))
      end

      def self.canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array then value.map { |entry| canonical(entry) }
        else value
        end
      end

      def initialize(context:, revision: REVISION)
        @network = Network::Definition.new(
          workspace: context.workspace,
          policy: Network::Policy.new,
          revision: revision
        )
        @metadata = Immutable.deep_freeze(
          { 'revision' => revision, 'runtime' => context.container_engine,
            'components' => component_definitions(context) }
        )
      end

      # rubocop:disable-next Metrics/AbcSize -- Aggregate fingerprints include dormant browser configuration.
      def component_definitions(context)
        @plan = ControlPlane::Plan.new(context: context)
        components = plan.definitions.merge(ControlPlane::Browser.new(plan).definitions).transform_values(&method(:safe_options))
        components['network'] = network.to_h
        components['egress'] = Network::Egress.new(workspace: context.workspace, policy: Network::Policy.new).to_h
        components
      end

      def safe_options(entry)
        options = entry.options.except('dns', 'runtime_environment', 'runtime_ip')
        options.merge('environment' => self.class.fingerprint(options.fetch('environment', {})))
      end

      def fingerprint
        self.class.fingerprint(metadata)
      end

      def component_fingerprints
        metadata.fetch('components').transform_values { |definition| self.class.fingerprint(definition) }
      end
    end
  end
end
