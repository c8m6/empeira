# frozen_string_literal: true

module Empeira
  module Node
    module ContainerLifecycle
      def start(name:)
        mutate do
          record = fetch(name)
          require_provisioned!(record)
          resource = observed(record)
          raise Error, 'Node is missing; destroy its reservation before recreating it' unless resource

          refresh_environment_cache
          changed = resource['state'] != 'running'
          @runtime.start_service(resource) if changed
          network_gateway.route(observed(record))
          refresh_dns
          changed = reconcile_guest(resource, record) || changed
          lifecycle_result(record['hostname'], :running, changed: changed)
        end
      end

      def stop(name:)
        mutate do
          resource = observed(fetch(name))
          raise Error, 'Node is missing; inspect node list' unless resource

          changed = resource['state'] == 'running'
          @runtime.stop_service(resource) if changed
          lifecycle_result(name.downcase, :stopped, changed: changed)
        end
      end

      def destroy(name:)
        mutate do
          @progress.stage(30, 'Removing node certificate and container...')
          changed = !!remove_node(name.downcase)
          refresh_dns if @state&.dig('resources', 'network', 'id')
          Providers::Result.new(resource: nil, changed: changed)
        end
      end

      def puppet(name:)
        mutate do
          record = fetch(name)
          require_provisioned!(record)
          ready_server
          @progress.stage(30, 'Running Puppet agent...')
          agent_run(running(record), record)
        end
      end

      def shell(name:)
        mutate do
          @runtime.stream_service(running(fetch(name)), RuntimeProxy.command(context, ['/bin/bash', '-i']),
                                  interactive: true)
        end
      end

      def ssh(name:, user: nil, identity: nil)
        mutate do
          record = fetch(name)
          resource = running(record)
          unless record['ssh_host'] && record['ssh_port']
            raise Error, 'Node has no managed SSH endpoint; destroy and recreate it with the current Empeira image'
          end

          proxy = @runtime.ssh_proxy_command(resource) if record['ssh_transport'] == 'tunnel'
          UserSSH.new(runner: @runner, credentials: ssh_credentials(record.fetch('hostname')),
                      proxy_command: proxy, home: context.locations.home).session(
                        record, user: user, identity: identity
                      )
        end
      end

      def logs(name:)
        load_state
        check_runtime!
        resource = observed(fetch(name))
        raise Error, 'Node container is missing' unless resource

        @runtime.stream_service(resource, [], logs: true)
      end

      private

      def require_provisioned!(record)
        return if record['provisioned']

        raise Error, 'Node bootstrap is incomplete; inspect logs or shell, then destroy and recreate the node'
      end

      def remove_node(name, certificates: true)
        record = @nodes[name]
        return unless record

        observed(record)
        if certificates && record['certificate_key']
          Certificates.new(runtime: @runtime, server: ready_server).clean(record)
        end
        @runtime.remove_service(definition(record), expected_id: record['id'])
        ssh_credentials(name).cleanup
        @nodes.delete(name)
        save
        true
      end

      def agent_run(resource, record)
        require_provisioned!(record)
        refresh_environment_cache
        reconcile_guest(resource, record)
        result = @progress.streaming do
          @runtime.stream_service(resource, RuntimeProxy.command(context, PuppetCommand.arguments))
        end
        record['last_puppet_exit'] = result.exit_status
        save
        return result if [0, 2].include?(result.exit_status)

        raise Error, "Puppet agent failed (exit #{result.exit_status}); node retained for shell/logs and another run"
      end
    end
  end
end
