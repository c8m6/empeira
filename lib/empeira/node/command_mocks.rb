# frozen_string_literal: true

module Empeira
  module Node
    # Reconciles guest resources under the existing workspace transaction.
    class CommandMocks
      def initialize(context:, record:, execute:, persist:)
        @context = context
        @record = record
        @execute = execute
        @persist = persist
      end

      def reconcile
        desired = @context.configuration.fetch('mocks').fetch('commands')
        return false if desired.empty? && @record.fetch('command_mocks', {}).empty?

        @entries = @record['command_mocks'] ||= {}
        changed = prune(desired)
        desired.each do |name, definition|
          changed = apply(name, definition) || changed
        end
        changed
      end

      def self.valid_inventory?(entries)
        return false unless entries.is_a?(Hash)

        entries.all? { |path, entry| valid_entry?(path, entry) }
      end

      def self.valid_entry?(path, entry)
        entry.is_a?(Hash) && (entry.keys - %w[name definition fingerprint previous]).empty? &&
          valid_definition?(path, entry['name'], entry['definition']) &&
          entry['fingerprint'] == Infrastructure::Definition.fingerprint(entry['definition']) &&
          (!entry.key?('previous') || valid_definition?(path, entry['name'], entry['previous']))
      end

      def self.valid_definition?(path, name, definition)
        Configuration::CommandMocks.validate!({ name => definition }, effective: true)
        definition['path'] == path
      rescue ConfigurationError
        false
      end

      private

      def resource(name, definition)
        CommandMock.new(command: name, definition: definition, workspace: @context.workspace, record: @record)
      end

      def accepted(entry)
        [entry.fetch('definition'), entry['previous']].compact.map do |definition|
          resource(entry.fetch('name'), definition).file.content
        end
      end

      def prune(desired)
        changed = false
        @entries.each_key do |path|
          entry = @entries.fetch(path)
          next if desired.dig(entry.fetch('name'), 'path') == path

          changed = execute(path, nil, accepted(entry)) || changed
          @entries.delete(path)
          @persist.call
        end
        changed
      end

      def apply(name, definition)
        path = definition.fetch('path')
        entry = @entries[path]
        return finish(entry) if entry && entry['definition'] == definition

        # Finish interrupted writes before accepting another desired revision.
        recovered = entry&.key?('previous') ? finish(entry) : false
        entry = { 'name' => name, 'definition' => definition,
                  'fingerprint' => Infrastructure::Definition.fingerprint(definition),
                  **(entry ? { 'previous' => entry.fetch('definition') } : {}) }
        @entries[path] = entry
        @persist.call
        finish(entry) || recovered
      end

      def finish(entry)
        file = resource(entry.fetch('name'), entry.fetch('definition')).file
        changed = execute(file.path, file.content, accepted(entry))
        @persist.call if entry.delete('previous')
        changed
      end

      def execute(path, content, accepted)
        helper = File.read(File.expand_path('../../../resources/nodes/managed_file.rb', __dir__))
        request = JSON.generate('path' => path, 'content' => content, 'accepted' => accepted, 'mode' => 0o755)
        result = @execute.call([Certificates::RUBY, '-e', helper, request])
        unless result.success?
          unless @execute.call([Certificates::RUBY, '--version']).success?
            raise Error,
                  "Cannot run node agent Ruby at #{Certificates::RUBY}; " \
                  'the agent installation or guest execution is unavailable. Inspect the node and its image.'
          end

          raise Providers::OwnershipError,
                "Cannot reconcile command mock at #{path}: unsafe target, cleanup conflict or guest I/O failure"
        end

        JSON.parse(result.stdout).fetch('changed')
      rescue JSON::ParserError, KeyError
        raise Error, "Cannot verify command-mock reconciliation at #{path}"
      end
    end
  end
end
