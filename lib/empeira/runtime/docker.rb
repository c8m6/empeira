# frozen_string_literal: true

module Empeira
  module Runtime
    class Docker < Container
      def initialize(context:, runner:)
        super(name: 'docker', context: context, runner: runner)
      end

      protected

      def remote_descriptors(image)
        result = metadata_command(['manifest', 'inspect', '--verbose', image], image: image)
        data = parse_json(result.stdout)
        entries = data.is_a?(Array) ? data : [data]
        entries.map { |entry| entry.is_a?(Hash) ? entry['Descriptor'] : nil }
      end

      def info_arguments
        ['info', '--format', '{{json .}}']
      end

      def validate_info!(info)
        malformed! unless info.is_a?(Hash) && info['ServerVersion'].is_a?(String)
        version = info['ServerVersion'][/\A\d+/].to_i
        return if version >= 28 && bridge_available?(info['Plugins']) && info['OSType'] == 'linux'

        raise UnsupportedCapability, 'Docker requires a Linux engine >= 28 with bridge and isolated gateway support'
      end

      def bridge_available?(plugins)
        plugins.is_a?(Hash) && plugins['Network'].is_a?(Array) && plugins['Network'].include?('bridge')
      end

      def network_entries
        output = command(['network', 'ls', '--no-trunc', '--format', '{{json .}}'],
                         operation: 'network inventory').stdout
        entries = output.lines.reject { |line| line.strip.empty? }.map do |line|
          item = parse_json(line)
          malformed! unless item.is_a?(Hash)
          { 'id' => item['ID'], 'name' => item['Name'] }
        end
        validate_entries(entries)
      end

      def create_arguments(definition)
        if definition.is_a?(Network::Egress)
          return ['network', 'create', '--driver', 'bridge', *label_arguments(definition), definition.backend_name]
        end

        ['network', 'create', '--driver', 'bridge', '--internal',
         '--opt', 'com.docker.network.bridge.gateway_mode_ipv4=isolated',
         '--opt', 'com.docker.network.bridge.gateway_mode_ipv6=isolated',
         *peer_network_options(definition), *label_arguments(definition), definition.backend_name]
      end

      def peer_network_options(definition)
        return [] unless definition.allocation

        layout = Network::Peer::Layout.new(definition.allocation)
        ['--subnet', layout.subnet, '--ip-range', layout.container_pool,
         '--opt', "com.docker.network.bridge.name=ep#{context.workspace.id[0, 10]}"]
      end

      def isolated_gateways?(options)
        %w[ipv4 ipv6].all? { |family| options["com.docker.network.bridge.gateway_mode_#{family}"] == 'isolated' }
      end

      def isolated?(data)
        data['Internal'] && data['Driver'] == 'bridge' && isolated_gateways?(data['Options'])
      end

      def normalize_network_binding(data)
        malformed! unless data['Options'].is_a?(Hash) && [true, false].include?(data['Internal'])
        Network::Binding.new(id: data['Id'], name: data['Name'], labels: data['Labels'] || {},
                             isolated: isolated?(data))
      end

      def normalize_network(data)
        binding = normalize_network_binding(data)
        containers = data['Containers']
        malformed! unless containers.is_a?(Hash)
        Network::Resource.new(**binding.to_h, attachment_count: containers.size)
      end
    end
  end
end
