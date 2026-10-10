# frozen_string_literal: true

require 'json'

module Empeira
  module Runtime
    class Unavailable < Providers::ExecutionError; end
    class UnsupportedCapability < Providers::ExecutionError; end

    # Keep the common network lifecycle and its failure semantics in one adapter boundary.
    # rubocop:disable-next Metrics/ClassLength
    class Container < Interface
      def available?
        check_available!
        true
      rescue Unavailable, UnsupportedCapability
        false
      end

      def check_available!
        @engine_info = json_command(info_arguments, operation: 'engine detection')
        validate_info!(@engine_info)
        true
      rescue Providers::ExecutionError => e
        raise if e.is_a?(UnsupportedCapability)

        raise Unavailable, "#{name} is unavailable. Install its CLI and start/reach its engine. #{e.message}",
              cause: nil
      end

      def architecture
        check_available! unless @engine_info
        cpu = @engine_info['Architecture'] || @engine_info.dig('host', 'arch')
        Platform::Facts.new(host_os: 'linux', host_cpu: cpu.to_s).architecture.to_s
      end

      def require_systemd!
        check_available! unless @engine_info
        return if name == 'podman' && @engine_info.dig('host', 'cgroupVersion') == 'v2'

        raise UnsupportedCapability, 'systemd nodes require Podman with cgroup v2; select node_defaults.init=process'
      end

      def node_ssh_publication?
        false
      end

      def capabilities
        { isolated: true, controlled_egress: false }
      end

      def inspect_network(identifier:)
        entry = network_entries.find { |item| [item.fetch('id'), item.fetch('name')].include?(identifier) }
        return unless entry

        inspect_entry(entry)
      end

      # rubocop:disable-next Naming/PredicateMethod -- Verification raises on failure.
      def verify_isolated_network(definition, expected_id:)
        data = json_command(['network', 'inspect', definition.backend_name],
                            operation: 'node network verification')
        malformed! unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
        binding = normalize_network_binding(data.first)
        definition.verify_ownership!(binding, expected_id: expected_id)
        definition.verify_definition!(binding)
        definition.verify_isolation!(binding)
        true
      end

      def create_network(definition:)
        definition.policy.require_support!(**capabilities)
        existing = inspect_network(identifier: definition.backend_name)
        if existing
          definition.verify_ownership!(existing)
          definition.verify_definition!(existing)
          definition.verify_isolation!(existing)
          return Providers::Result.new(resource: existing, changed: false)
        end

        mutate_network(definition, 'create', create_arguments(definition))
        resource = inspect_network(identifier: definition.backend_name)
        definition.verify_ownership!(resource)
        definition.verify_isolation!(resource)
        Providers::Result.new(resource: resource, changed: true)
      end

      def remove_network(definition:, expected_id: nil)
        resource = inspect_network(identifier: definition.backend_name)
        definition.verify_ownership!(resource, expected_id: expected_id)
        return Providers::Result.new(resource: nil, changed: false) unless resource

        raise Providers::ExecutionError, "#{name} network still has attached resources; detach them before down" unless
          resource.attachment_count.zero?

        mutate_network(definition, 'remove', ['network', 'rm', resource.id])
        if inspect_network(identifier: definition.backend_name)
          raise Providers::ExecutionError, "#{name} network removal could not be verified"
        end

        Providers::Result.new(resource: nil, changed: true)
      end

      def network_subnets
        network_entries.flat_map do |entry|
          data = json_command(['network', 'inspect', entry.fetch('id')], operation: 'subnet inventory').first
          subnets = data['subnets'] || data.dig('IPAM', 'Config') || []
          subnets.filter_map { |item| item['subnet'] || item['Subnet'] }
        end
      end

      def network_details(identifier)
        json_command(['network', 'inspect', identifier], operation: 'peer network inspection').first
      end

      protected

      def command(arguments, operation:)
        result = runner.run(name, arguments: arguments, timeout: 30)
        return result if result.success?

        outcome = result.timed_out ? 'timed out' : "exit #{result.exit_status.inspect}"
        raise Providers::ExecutionError,
              "#{name} #{operation} failed (#{outcome}) for workspace #{context.workspace.id}"
      rescue Empeira::ExecutionError
        raise Providers::ExecutionError,
              "#{name} #{operation} could not execute. Check CLI installation and permissions.",
              cause: nil
      end

      def json_command(arguments, operation:)
        parse_json(command(arguments, operation: operation).stdout)
      end

      def parse_json(output)
        JSON.parse(output)
      rescue JSON::ParserError
        malformed!
      end

      def malformed!
        raise Providers::ExecutionError, "#{name} returned malformed network/engine data", cause: nil
      end

      def label_arguments(definition)
        definition.labels.flat_map { |key, value| ['--label', "#{key}=#{value}"] }
      end

      def validate_entries(entries)
        unless entries.is_a?(Array) && entries.all? do |item|
          item.is_a?(Hash) && %w[id name].all? do |key|
            item[key].is_a?(String) && item[key].match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
          end
        end
          malformed!
        end
        entries
      end

      private

      def inspect_entry(entry)
        data = json_command(['network', 'inspect', entry.fetch('id')], operation: 'network inspection')
        malformed! unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
        resource = normalize_network(data.first)
        malformed! unless resource.id == entry.fetch('id') && resource.name == entry.fetch('name')
        resource
      end

      def mutate_network(definition, operation, arguments)
        command(arguments, operation: "network #{operation}")
      rescue Providers::ExecutionError, Interrupt => e
        # A failed command may have committed. Inspect once, never blindly retry.
        observed = inspect_network(identifier: definition.backend_name)
        definition.verify_ownership!(observed)
        raise e if e.is_a?(Interrupt)

        outcome = observed ? 'present' : 'absent'
        raise Providers::ExecutionError, "#{e.message}. Network observed #{outcome}; run status before retrying.",
              cause: nil
      end
    end
  end
end
