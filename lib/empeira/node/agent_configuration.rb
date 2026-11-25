# frozen_string_literal: true

require 'json'

module Empeira
  module Node
    # Apply native Puppet settings through one guest Ruby process for both providers.
    module AgentConfiguration
      APPLY = <<~RUBY
        require 'json'
        require 'puppet'
        require 'puppet/face'
        Puppet.initialize_settings
        config = Puppet::Face[:config, '0.0.1']
        JSON.parse(ARGV.fetch(0)).each { |key, value| config.set(key, value, section: 'main') }
      RUBY

      def self.apply(record:, environment:, execute:)
        settings = { 'certname' => record.fetch('hostname'), 'server' => 'server.empeira.internal',
                     'environment' => environment }
        result = execute.call([Certificates::RUBY, '-e', APPLY, JSON.generate(settings)])
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Node agent configuration', tool: 'puppet')
        raise Error, "Node agent configuration failed; node retained for diagnosis\n#{details}", cause: nil
      end
    end
  end
end
