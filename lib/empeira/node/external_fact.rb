# frozen_string_literal: true

module Empeira
  module Node
    # One public logical provider fact is present before the first catalog.
    module ExternalFact
      PATH = '/etc/puppetlabs/facter/facts.d/empeira.yaml'
      PROVIDERS = %w[container vm].freeze

      def self.content(provider)
        raise ConfigurationError, 'Unknown Empeira node provider' unless PROVIDERS.include?(provider)

        "empeira:\n  provider: #{provider}\n"
      end
    end
  end
end
