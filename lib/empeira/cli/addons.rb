# frozen_string_literal: true

require_relative 'base'

module Empeira
  module CLI
    class Addons < Base
      desc 'list', 'List configured addons and local installation status'
      def list
        service = application.addons
        service.names.each do |name|
          say "#{name}: #{local_status(service.installation(name))}"
        end
      end

      desc 'info NAME', 'Show source, reference, commit, path and manifest'
      def info(name)
        entry = application.addons.installation(name)
        say "Addon: #{name}\nGit: #{entry.source}\nRef: #{entry.ref}"
        local = entry.local
        return say('Status: missing; run empeira addons sync') unless local

        commit, path, manifest = local
        say "Commit: #{commit}\nPath: #{path}\n#{YAML.dump(manifest.data)}"
      end

      %w[sync update].each do |operation|
        desc operation, 'Synchronize configured Git addons without starting infrastructure'
        define_method(operation) do
          application.addons.synchronize
          say 'Configured addons synchronized.'
        end
      end

      no_commands do
        def local_status(entry)
          local = entry.local
          local ? "installed (#{entry.ref}, #{local.first})" : "missing (#{entry.ref})"
        rescue Empeira::Addons::Error => e
          "invalid (#{e.message})"
        end
      end
    end
  end
end
