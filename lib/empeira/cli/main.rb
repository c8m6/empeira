# frozen_string_literal: true

require_relative 'base'
require_relative 'config'
require_relative 'node'
require_relative 'proxy'
require_relative 'completion'
require_relative 'update'

module Empeira
  module CLI
    class Main < Base
      desc 'version', 'Show build version'
      option :verbose, type: :boolean, desc: 'Include revision and build time'
      map '--version' => :version
      def version
        info = BuildInfo.load
        say(options[:verbose] ? JSON.pretty_generate(info.to_h) : "Empeira #{info.version}")
      end

      desc 'config SUBCOMMAND', 'Show or validate project configuration'
      subcommand 'config', Config
      desc 'proxy SUBCOMMAND', 'Explain hostname-specific proxy policy'
      subcommand 'proxy', Proxy
      desc 'node SUBCOMMAND', 'Container and VM test-node lifecycle'
      subcommand 'node', Node
      desc 'completion SUBCOMMAND', 'Shell completion'
      subcommand 'completion', Completion

      desc 'status', 'Inspect workspace infrastructure without changing state'
      def status
        application.infrastructure.status.each { |key, value| say "#{key}: #{value}" }
      end

      desc 'up', 'Ensure isolated workspace infrastructure'
      def up
        result = progressing('Preparing workspace...') { |app| app.infrastructure.up }
        say(result.changed ? 'Workspace control plane is ready.' : 'Workspace control plane is already ready.')
      end

      desc 'browser', 'Start the disposable internal browser and print its loopback HTTPS URL'
      def browser
        url = progressing('Preparing internal browser...') { |app| app.infrastructure.browser }
        say url
      end

      desc 'down', 'Remove owned workspace infrastructure'
      def down
        result = progressing('Stopping workspace...') { |app| app.infrastructure.down }
        action = result.changed ? 'removed' : 'already absent'
        say "Workspace services #{action}; persistent data retained."
      end

      desc 'destroy', 'Permanently remove services, CA and database volumes'
      def destroy
        progressing('Removing workspace...', recovery: true) { |app| app.infrastructure.destroy }
        say 'Workspace infrastructure and persistent data removed.'
      end

      desc 'self-update', 'Update only Empeira (not implemented yet)'
      def self_update
        Updates::Service.new.self_update
      end

      desc 'update SUBCOMMAND', 'Update managed targets (not implemented yet)'
      subcommand 'update', Update

      %w[images].each do |operation|
        desc "#{operation} [SUBCOMMAND]", 'Not implemented yet'
        define_method(operation) do |*_arguments|
          raise UnavailableFeature, 'This command is not implemented yet.'
        end
      end
    end
  end
end
