# frozen_string_literal: true

module Empeira
  module Node
    # rubocop:disable-next Metrics/ModuleLength -- Provider lifecycle operations share one ownership boundary.
    module ContainerLifecycle
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Keep native resource creation and readiness separate from brief identity publication.
      def start(name:)
        mutate do
          record = fetch(name)
          require_provisioned!(record)
          record = claim_lifecycle(name)
          resource = observed(record)
          raise Error, 'Node is missing; destroy its reservation before recreating it' unless resource

          ready_server
          changed = resource['state'] != 'running'
          instance_phase(record) do
            @runtime.start_service(resource) if changed
            network_gateway.route(observed(record))
            refresh_dns
          end
          changed = reconcile_guest(resource, record) || changed
          lifecycle_result(record['hostname'], :running, changed: changed)
        end
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Invalidate pending lifecycle work and interrupt the native instance before waiting for its resource phase.
      def stop(name:)
        mutate(destructive: true) do
          record = fetch(name)
          cancel_lifecycle(record)
          resource = observed(record)
          changed = resource && resource['state'] == 'running'
          @runtime.stop_service(resource) if changed
          instance_phase(record) do
            cancel_lifecycle(record)
            load_state
            record = fetch(name)
            resource = observed(record)
            changed ||= resource && resource['state'] == 'running'
            @runtime.stop_service(resource) if resource && resource['state'] == 'running'
            lifecycle_result(name.downcase, :stopped, changed: !!changed)
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
        client, record = mutate do
          current = fetch(name)
          resource = running(current)
          instance_phase(current) do
            client, endpoint = prepare_ssh(current, resource, port)
            client.prepare(endpoint, user: user, identity: identity)
            [client, endpoint]
          end
        end
        Execution::Terminal.with_interrupts do
          @progress.streaming { client.session(record, user: user, identity: identity) }
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

      # rubocop:disable-next Metrics/AbcSize -- Pin the native instance and its private known-hosts location before session handoff.
      def prepare_ssh(record, resource, port)
        port = Configuration::SSHPreferences.port!(port || 22)
        unless record['ssh_host'] && record['ssh_port']
          raise Error, 'Node has no managed SSH endpoint; destroy and recreate it with the current Empeira image'
        end

        proxy = port == 22 ? @runtime.ssh_proxy_command(resource) : @runtime.ssh_proxy_command(resource, port: port)
        credentials = SSHCredentials.new(context: context, runner: @runner, provider: 'container',
                                         hostname: record.fetch('hostname'), instance: Inventory.instance(record))
        client = UserSSH.new(runner: @runner, credentials: credentials,
                             proxy_command: proxy, home: context.locations.home)
        [client, port == 22 ? record : record.merge('ssh_port' => port)]
      end

      def require_provisioned!(record)
        return if record['provisioned']

        raise Error, 'Node bootstrap is incomplete; inspect logs or shell, then destroy and recreate the node'
      end

      def agent_run(resource, record, initial: false)
        require_provisioned!(record)
        reconcile_provider_fact(resource, record)
        result = @progress.streaming do
          arguments = RuntimeProxy.command(context, PuppetCommand.arguments)
          initial ? @runtime.diagnostic_exec(resource, arguments) : @runtime.stream_service(resource, arguments)
        end
        record_completion(record, result)
        return result if initial || [0, 2].include?(result.exit_status)

        raise Error, "Puppet agent failed (exit #{result.exit_status}); node retained for shell/logs and another run"
      end
    end
  end
end
