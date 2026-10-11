# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class Backend
        attr_reader :context, :runtime, :runner, :store

        def self.build(context:, **)
          klass = if context.container_engine == 'docker'
                    DockerAdapter
                  elsif context.platform.os == :macos
                    PodmanMachine
                  else
                    LinuxPodman
                  end
          klass.new(context: context, **)
        end

        def initialize(context:, runtime:, runner:, store:)
          @context = context
          @runtime = runtime
          @runner = runner
          @store = store
        end

        def key
          self.class.name.split('::').last
        end

        def preflight(state)
          raise Error, 'Old VM network state requires explicit teardown and recreation' unless state['peer_network']

          resource = owned_network(state)
          details = runtime.network_details(resource.id)
          verify_subnet(details, state.fetch('peer_network').fetch('subnet'))
        end

        def owned_network(state)
          definition = Network::Definition.new(workspace: context.workspace, policy: Network::Policy.new)
          resource = runtime.inspect_network(identifier: definition.backend_name)
          definition.verify_ownership!(resource, expected_id: state.dig('resources', 'network', 'id'))
          definition.verify_isolation!(resource)
          raise Error, 'Owned peer network is missing; run empeira up' unless resource

          resource
        end

        def verify_subnet(details, expected)
          subnets = details['subnets'] || details.dig('IPAM', 'Config') || []
          return if subnets.any? { |entry| (entry['subnet'] || entry['Subnet']) == expected }

          raise Providers::OwnershipError, 'Observed peer subnet differs from workspace inventory'
        end

        def network_name
          Network::Definition.new(workspace: context.workspace, policy: Network::Policy.new).backend_name
        end

        def bridge
          "ep#{context.workspace.id[0, 10]}"
        end

        def tap(record)
          "et#{record.fetch('peer').fetch('token')[0, 12]}"
        end

        def command(executable, *arguments, timeout: 30)
          result = runner.run(executable, arguments: arguments, timeout: timeout)
          return result.stdout if result.success?

          raise Error,
                "Peer network #{executable} operation failed (exit=#{result.exit_status}, timeout=#{result.timed_out})"
        end

        def check_record(record)
          return if record.dig('peer', 'backend') == key

          raise Error, 'Peer backend differs from the node instance; restore its runtime and platform'
        end

        def health(records)
          records.to_h { |record| [record.fetch('hostname'), healthy?(record)] }
        end

        def system_address(record, port)
          Configuration::SSHPreferences.port!(port)
          check_record(record)
          address = IPAddr.new(record.fetch('peer').fetch('ip'))
          subnet = system_subnet
          unless address.ipv4? && address.private? && subnet.include?(address)
            raise Providers::OwnershipError, 'System SSH target is outside the owned peer subnet'
          end

          address.to_s
        end

        def system_subnet
          state = store.load
          resource = owned_network(state)
          subnet = state.fetch('peer_network').fetch('subnet')
          verify_subnet(runtime.network_details(resource.id), subnet)
          IPAddr.new(subnet)
        end
      end
    end
  end
end
