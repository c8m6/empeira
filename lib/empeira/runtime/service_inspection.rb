# frozen_string_literal: true

module Empeira
  module Runtime
    module ServiceInspection
      def inspect_services(definitions, expected_ids: {})
        selected = select_services(definitions, expected_ids)
        ids = selected.values.compact.map { |entry| entry.fetch('id') }
        resources = inspect_containers(ids)
        definitions.to_h do |key, definition|
          resource = resources[selected[key]&.fetch('id')]
          definition.verify!(resource, expected_id: expected_ids[key])
          [key, resource]
        end
      end

      private

      def select_services(definitions, expected_ids)
        entries = inventory('container')
        definitions.to_h do |key, definition|
          entry = entries.find { |item| item.fetch('name') == definition.name }
          verify_recorded_name!('container', entries, entry, expected_ids[key])
          [key, entry]
        end
      end

      def inspect_containers(ids)
        return {} if ids.empty?

        data = parse_json(service_command(['container', 'inspect', *ids], operation: 'service snapshot').stdout)
        validate_snapshot!(data, ids.size)
        resources = data.map { |entry| normalize_service('container', entry) }
        verify_snapshot_ids!(resources, ids)
        resources.to_h { |entry| [entry.fetch('id'), entry] }
      rescue KeyError, TypeError, NoMethodError
        malformed!
      end

      def validate_snapshot!(data, size)
        malformed! unless data.is_a?(Array) && data.size == size && data.all?(Hash)
      end

      def verify_snapshot_ids!(resources, ids)
        malformed! unless resources.map { |entry| entry['id'] }.sort == ids.sort
      end

      def inspect_owned(kind, definition, expected_id:)
        entries = inventory(kind)
        entry = entries.find { |item| item.fetch('name') == definition.name }
        verify_recorded_name!(kind, entries, entry, expected_id)
        return unless entry

        resource = normalize_service(kind, inspect_entry_data(kind, entry.fetch('id')))
        definition.verify!(resource, expected_id: expected_id)
        resource
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError
        raise Providers::ExecutionError, 'Malformed service inventory', cause: nil
      end

      def verify_recorded_name!(kind, entries, entry, expected_id)
        return unless kind == 'container' && !entry && expected_id
        return unless entries.any? { |item| item.fetch('id') == expected_id }

        raise Providers::OwnershipError, "Recorded #{kind} exists under a different name"
      end

      def inspect_entry_data(kind, id)
        data = JSON.parse(service_command([kind, 'inspect', id], operation: "#{kind} inspection").stdout)
        unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
          raise Providers::ExecutionError, 'Malformed service inspection'
        end

        data.first
      end

      def inventory(kind)
        args = kind == 'container' ? ['ps', '--all', '--no-trunc'] : %w[volume ls]
        # Both CLIs support Go templates independently of their JSON inspection casing.
        if kind == 'container'
          output = service_command([*args, '--format', '{{.ID}} {{.Names}}'],
                                   operation: 'service inventory')
        end
        output ||= service_command([*args, '--format', '{{.Name}}'], operation: 'volume inventory')
        output.stdout.lines.reject { |line| line.strip.empty? }.map do |line|
          id, item_name = line.strip.split(' ', 2)
          { 'id' => id, 'name' => item_name || id }
        end
      end

      def normalize_volume(data)
        { 'id' => data.fetch('Labels', {}).fetch('io.empeira.volume-id', data.fetch('Name')),
          'name' => data.fetch('Name'), 'labels' => data['Labels'] || {} }
      end

      def normalize_service(kind, data)
        return normalize_volume(data) if kind == 'volume'

        { 'id' => data.fetch('Id'), 'name' => data.fetch('Name').delete_prefix('/'),
          'labels' => data.fetch('Config')['Labels'] || {}, 'state' => data.fetch('State').fetch('Status'),
          'networks' => data.fetch('NetworkSettings').fetch('Networks'),
          'host_config' => data['HostConfig'], 'image_id' => data['Image'],
          'mounts' => data.fetch('Mounts'), 'dns' => data.dig('HostConfig', 'Dns') || [],
          **port_observations(data) }
      end

      def port_observations(data)
        { 'ports' => data.dig('HostConfig', 'PortBindings') || {},
          'published_ports' => data.dig('NetworkSettings', 'Ports') || {} }
      end
    end
  end
end
