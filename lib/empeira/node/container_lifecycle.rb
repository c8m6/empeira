# frozen_string_literal: true

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- Provider lifecycle operations share one ownership boundary.
    module ContainerLifecycle
      def start(name:)
        mutate do
          record = fetch(name)
          require_provisioned!(record)
          resource = observed(record)
          raise Error, 'Node is missing; destroy its reservation before recreating it' unless resource

          ready_server
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
          record = fetch(name)
          resource = observed(record)
          raise Error, 'Node is missing; inspect node list' unless resource

          SessionLock.new(context: context, record: record).exclusive do
            changed = resource['state'] == 'running'
            @runtime.stop_service(resource) if changed
            lifecycle_result(name.downcase, :stopped, changed: changed)
          end
        end
      end

      def destroy(name:)
        Infrastructure::Cleanup.new(context: context, runner: @runner, runtime: @runtime,
                                    progress: @progress).node(name)
      end

      def puppet(name:)
        mutate(availability: false) do
          record = fetch(name)
          require_provisioned!(record)
          resource = running(record)
          ready_network!
          @progress.stage(30, 'Running Puppet agent...')
          agent_run(resource, record)
        end
      end

      def shell(name:)
        mutate do
          resource = running(fetch(name))
          raise Error, 'Node shell requires a local terminal' unless $stdin.tty? && $stdout.tty?

          arguments = RuntimeProxy.command(context, ['env', 'HISTFILE=/dev/null', '/bin/bash', '-i'])
          @runtime.stream_service(resource, arguments, interactive: true, user: '0')
        end
      end

      def console(name:)
        raise Error, "Container node #{name} has no serial VM console; use node shell or node exec"
      end

      def exec(name:, arguments:, timeout: nil, output: $stdout, error: $stderr)
        DiagnosticCommand.validate!(arguments, timeout)
        mutate do
          Execution::Terminal.with_interrupts do
            @progress.streaming do
              @runtime.diagnostic_exec(running(fetch(name)), arguments, timeout: timeout, output: output, error: error)
            end
          end
        end
      end

      def ssh(name:, user: nil, identity: nil, port: nil)
        lock = nil
        client, record = mutate do
          current = fetch(name)
          resource = running(current)
          lock = SessionLock.new(context: context, record: current).acquire(shared: true)
          prepare_ssh(current, resource, port)
        end
        Execution::Terminal.with_interrupts do
          @progress.streaming { client.session(record, user: user, identity: identity) }
        end
      ensure
        lock&.close
      end

      def logs(name:)
        load_state
        check_runtime!
        resource = observed(fetch(name))
        raise Error, 'Node container is missing' unless resource

        @runtime.stream_service(resource, [], logs: true)
      end

      private

      def prepare_ssh(record, resource, port)
        port = Configuration::SSHPreferences.port!(port || 22)
        unless record['ssh_host'] && record['ssh_port']
          raise Error, 'Node has no managed SSH endpoint; destroy and recreate it with the current Empeira image'
        end

        proxy = if port != 22
                  @runtime.ssh_proxy_command(resource, port: port)
                elsif record['ssh_transport'] == 'tunnel'
                  @runtime.ssh_proxy_command(resource)
                end
        client = UserSSH.new(runner: @runner, credentials: ssh_credentials(record.fetch('hostname')),
                             proxy_command: proxy, home: context.locations.home)
        [client, port == 22 ? record : record.merge('ssh_port' => port)]
      end

      def require_provisioned!(record)
        return if record['provisioned']

        raise Error, 'Node bootstrap is incomplete; inspect logs or shell, then destroy and recreate the node'
      end

      def remove_node(name, certificates: true)
        record = @nodes[name]
        return unless record

        SessionLock.new(context: context, record: record).exclusive do
          remove_node_instance(name, record, certificates: certificates)
        end
      end

      # rubocop:disable-next Naming/PredicateMethod -- Removes an owned instance and persists its absence.
      def remove_node_instance(name, record, certificates:)
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
        reconcile_provider_fact(resource, record)
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
