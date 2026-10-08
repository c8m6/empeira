# frozen_string_literal: true

module Empeira
  module Runtime
    class Podman < Container
      def node_ssh_publication?
        true
      end

      def initialize(context:, runner:)
        super(name: 'podman', context: context, runner: runner)
      end

      protected

      # A disposable manifest forces registry access even if the tag exists locally.
      # Podman resolves both single manifests and indexes without downloading layers.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Keep manifest ownership, deadline and cleanup in one transaction.
      def remote_descriptors(image)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        temporary = "localhost/empeira-metadata-#{SecureRandom.hex(16)}"
        result = update_command(['manifest', 'create', temporary], operation: 'temporary metadata creation', timeout: 5)
        identifier = result.stdout.strip
        unless identifier.match?(/\A[0-9a-f]{64}\z/)
          raise Providers::ExecutionError,
                'Invalid temporary manifest identity'
        end

        metadata_command(['manifest', 'add', '--all', identifier, "docker://#{image}"],
                         image: image, timeout: metadata_remaining(deadline))
        result = metadata_command(['manifest', 'inspect', identifier], image: image,
                                                                       timeout: metadata_remaining(deadline))
        data = parse_json(result.stdout)
        malformed! unless data.is_a?(Hash) && data['manifests'].is_a?(Array)
        data['manifests']
      ensure
        if identifier&.match?(/\A[0-9a-f]{64}\z/)
          update_command(['manifest', 'rm', identifier], operation: 'temporary metadata cleanup', timeout: 5)
        end
      end

      def metadata_remaining(deadline)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Providers::ExecutionError, 'Remote metadata timeout' unless remaining.positive?

        remaining
      end

      def update_helper_user
        ['--userns', 'keep-id', *super]
      end

      def update_helper_network
        'podman'
      end

      def info_arguments
        ['info', '--format', 'json']
      end

      def validate_info!(info)
        malformed! unless info.is_a?(Hash) && info['host'].is_a?(Hash)
        return if info.dig('host', 'networkBackend') == 'netavark' &&
                  bridge_available?(info['plugins'])

        raise UnsupportedCapability, 'Podman requires the Netavark network backend with bridge support'
      end

      def bridge_available?(plugins)
        plugins.is_a?(Hash) && plugins['network'].is_a?(Array) && plugins['network'].include?('bridge')
      end

      def network_entries
        entries = json_command(['network', 'ls', '--format', 'json'], operation: 'network inventory')
        malformed! unless entries.is_a?(Array) && entries.all?(Hash)
        validate_entries(entries.map { |item| { 'id' => item['id'], 'name' => item['name'] } })
      end

      def create_arguments(definition)
        if definition.is_a?(Network::Egress)
          return ['network', 'create', '--driver', 'bridge', *label_arguments(definition), definition.backend_name]
        end

        ['network', 'create', '--driver', 'bridge', '--internal', '--disable-dns',
         '--opt', 'isolate=true', *peer_network_options(definition), *label_arguments(definition),
         definition.backend_name]
      end

      def attachment_count(identifier)
        entries = json_command(['ps', '--all', '--filter', "network=#{identifier}", '--format', 'json'],
                               operation: 'network membership')
        malformed! unless entries.is_a?(Array) && entries.all?(Hash)
        entries.size
      end

      def peer_network_options(definition)
        return [] unless definition.allocation

        layout = Network::Peer::Layout.new(definition.allocation)
        ['--subnet', layout.subnet, '--ip-range', layout.container_pool,
         '--interface-name', "ep#{context.workspace.id[0, 10]}"]
      end

      def isolated?(data)
        data['internal'] && data['driver'] == 'bridge' && data['dns_enabled'] == false &&
          data['options']['isolate'] == 'true'
      end

      def normalize_network(data)
        data = data.merge('options' => data['options'] || {})
        malformed! unless [true, false].include?(data['internal']) && data['options'].is_a?(Hash)
        Network::Resource.new(id: data['id'], name: data['name'], labels: data['labels'] || {},
                              isolated: isolated?(data), attachment_count: attachment_count(data['id']))
      end
    end
  end
end
