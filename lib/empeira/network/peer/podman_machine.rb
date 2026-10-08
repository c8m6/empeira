# frozen_string_literal: true

require 'shellwords'

module Empeira
  module Network
    module Peer
      class PodmanMachine < DockerAdapter
        def preflight(state)
          super
          select_machine
          verify_rootless
          namespace('test', '-w', '/dev/net/tun')
          raise Error, 'Machine peer bridge routing is enabled' unless
            namespace('cat', "/proc/sys/net/ipv4/conf/#{bridge}/forwarding").strip == '0'
        end

        def prepare(record, state)
          check_record(record)
          bind_machine(record, state)
          channel(record).prepare
          @image = AdapterImage.new(context: context)
          @image.ensure!(runtime)
          resource = ensure_adapter(record, state)
          runtime.start_service(resource) unless resource['state'] == 'running'
          export_helper(record, resource)
          store.write(state)
        end

        protected

        def adapter_definition(record)
          Services::Definition.new(key: identity(record).key, workspace: context.workspace,
                                   network: network_name, image: @image.image, memory: 64, cpus: 1,
                                   command: ['hold'], read_only: true, cap_drop: ['ALL'],
                                   security_options: ['no-new-privileges'])
        end

        def packet_command(record)
          machine = record.fetch('peer').fetch('machine')
          namespace_command(machine, helper_path(record).to_s, 'tap', tap(record), bridge)
        end

        def helper_path(record)
          context.locations.workspace(context.workspace).join('vms', record.fetch('hostname'), 'peer-adapter')
        end

        private

        def bind_machine(record, state)
          if record.dig('peer', 'machine') && record.dig('peer', 'machine') != @machine
            raise Providers::OwnershipError, 'Node belongs to a different Podman Machine'
          end

          record.fetch('peer')['machine'] = @machine
          store.write(state)
        end

        def selected_connection
          connections = JSON.parse(command('podman', 'system', 'connection', 'list', '--format', 'json'))
          connections.select { |entry| entry['Default'] }
        end

        def select_machine
          machines = JSON.parse(command('podman', 'machine', 'list', '--format', 'json'))
          active = machines.select { |entry| entry['Running'] }
          selected = selected_connection
          unless active.size == 1 && selected.size == 1 && selected.first['Name'] == active.first['Name']
            raise Error, 'Select one unambiguous running rootless Podman Machine and its default connection'
          end

          @machine = active.first.fetch('Name')
        end

        def verify_rootless
          info = JSON.parse(command('podman', 'info', '--format', 'json'))
          return if info.dig('host', 'security', 'rootless') && info.dig('host', 'networkBackend') == 'netavark'

          raise Error, 'Podman Machine peer networking requires rootless Netavark; no rootful fallback'
        end

        def verify_empty_capabilities(resource)
          result = runtime.service_exec(resource, %w[/adapter capabilities])
          return if result.success? && result.stdout.strip.match?(/\A0{16}\z/)

          raise Providers::OwnershipError, 'Podman staging helper must have no effective capabilities'
        end

        def export_helper(record, resource)
          path = helper_path(record)
          runtime.copy_from(resource, '/adapter', path)
          verify_empty_capabilities(resource)
          digest = verify_adapter(record)
          raise Error, 'Exported peer helper checksum mismatch' unless Digest::SHA256.file(path).hexdigest == digest

          File.chmod(0o700, path)
          observed = command('podman', 'machine', 'ssh', @machine,
                             Shellwords.join(['sha256sum', path.to_s])).split.first
          return if observed == digest

          raise Error, 'Podman Machine cannot verify the peer helper at its host path; configure its shared mount'
        end

        def namespace(*)
          executable, *arguments = namespace_command(@machine, *)
          command(executable, *arguments)
        end

        def namespace_command(machine, *)
          ['podman', 'machine', 'ssh', machine, Shellwords.join(['podman', 'unshare', '--rootless-netns', *])]
        end
      end
    end
  end
end
