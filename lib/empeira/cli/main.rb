# frozen_string_literal: true

require_relative 'base'
require_relative 'config'
require_relative 'node'
require_relative 'proxy'
require_relative 'completion'
require_relative 'update'
require_relative 'addons'

module Empeira
  module CLI
    class Main < Base
      # Strip the opaque addon argv before Thor can interpret --help, --version,
      # assignments, or a literal -- as Core options.
      def self.start(given_args = ARGV, config = {})
        index = addon_index(given_args)
        if index && given_args[index + 1]&.match?(Configuration::Addons::NAME)
          config = config.merge(addon_arguments: given_args.drop(index + 2))
          given_args = [*given_args[index, 2], *given_args.take(index)]
        end
        super
      end

      def self.addon_index(arguments)
        index = 0
        index += arguments[index].include?('=') ? 1 : 2 while arguments[index]&.start_with?('--container-engine')
        index if arguments[index] == 'addon'
      end

      desc 'addon NAME [ARGUMENTS...]', 'Run a configured standalone addon'
      def addon(name)
        application.addons.execute(name, @addon_arguments || [])
      end

      desc 'addons SUBCOMMAND', 'Manage configured Git addons'
      subcommand 'addons', Addons

      desc 'version', 'Show build version'
      option :verbose, type: :boolean, desc: 'Include revision and build time'
      map '--version' => :version
      def version
        require 'json' if options[:verbose]
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
      option :verify, type: :boolean, default: false, desc: 'Also verify live gateway and bridge policy'
      def status
        application.infrastructure.status(verify: options[:verify]).each { |key, value| say "#{key}: #{value}" }
      end

      desc 'up', 'Ensure isolated workspace infrastructure'
      def up
        addon_error = nil
        result = progressing('Preparing workspace...') do |app|
          ready = app.infrastructure.up
          begin
            app.addons.synchronize(missing_only: true)
          rescue Empeira::Addons::Error => e
            addon_error = e
          end
          ready
        end
        say(result.changed ? 'Workspace control plane is ready.' : 'Workspace control plane is already ready.')
        raise addon_error if addon_error
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
      option :project_path, type: :string,
                            desc: 'Former absolute Git root path for recovery without a control repository'
      def destroy
        progressing('Removing workspace...', recovery: true) { |app| app.infrastructure.destroy }
        say 'Workspace infrastructure and persistent data removed.'
      end

      desc 'self-update', 'Update Empeira to the latest stable version via RubyGems'
      def self_update
        say 'Updating Empeira via RubyGems...'
        previous, installed = Updates::Service.new.self_update
        say(installed > previous.version ? 'Empeira updated successfully.' : 'Empeira is already up to date.')
        say "Installed version: #{installed}"
      end

      desc 'update SUBCOMMAND', 'Update Empeira and managed artifacts'
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
