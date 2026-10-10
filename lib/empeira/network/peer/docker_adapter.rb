# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      # The same whole-NIC transport serves local Docker and Docker Desktop.
      # rubocop:disable-next Metrics/ClassLength -- Owned NIC and system SSH share adapter security checks.
      class DockerAdapter < Backend
        def preflight(state)
          super
          return if runtime.architecture == context.platform.architecture.to_s

          raise Error, 'Peer adapter and VM architecture differ; emulation is not supported'
        end

        def prepare(record, state)
          check_record(record)
          channel(record).prepare
          @image = AdapterImage.new(context: context)
          @image.ensure!(runtime)
          resource = ensure_adapter(record, state)
          runtime.start_service(resource) unless resource['state'] == 'running'
          verify_adapter(record)
          store.write(state)
          attach_bridge(resource)
        end

        def arguments(record)
          ['-netdev', "stream,id=peer,addr.type=unix,addr.path=#{channel(record).socket},server=on",
           '-device', "virtio-net-pci,netdev=peer,mac=#{record.fetch('mac_address')}"]
        end

        def launch(executable, arguments)
          command(executable, *arguments)
        end

        def connect(record, _state)
          File.chmod(0o600, channel(record).socket)
          channel(record).start(packet_command(record))
        end

        def stop(record)
          channel(record).stop
        end

        def destroy(record, state)
          channel(record).destroy
          runtime.remove_service(identity(record), expected_id: record.dig('peer', 'adapter_id'))
          record.fetch('peer')['adapter_id'] = nil
          store.write(state)
        end

        def healthy?(record)
          channel(record).healthy?
        end

        def system_ssh_command(record, port:)
          address = system_address(record, port)
          @image = AdapterImage.new(context: context)
          verify_adapter(record)
          resource = runtime.inspect_service(identity(record), expected_id: record.dig('peer', 'adapter_id'))
          verify_definition!(record, resource)
          raise Providers::OwnershipError, 'VM peer channel is not active' unless healthy?(record)

          ['docker', 'exec', '-i', resource.fetch('id'), '/adapter', 'connect', address, port.to_s]
        end

        protected

        def channel(record)
          Channel.new(context: context, runner: runner, record: record)
        end

        def identity(record)
          Services::Definition.new(key: "peer-#{record.fetch('peer').fetch('token')[0, 16]}",
                                   workspace: context.workspace)
        end

        def adapter_definition(record)
          Services::Definition.new(key: identity(record).key, workspace: context.workspace,
                                   network: network_name, image: @image.image, memory: 64, cpus: 1,
                                   command: ['hold'], read_only: true, cap_drop: ['ALL'], cap_add: ['NET_ADMIN'],
                                   devices: ['/dev/net/tun'], security_options: ['no-new-privileges'],
                                   sysctls: { 'net.ipv4.ip_forward' => '0', 'net.ipv6.conf.all.disable_ipv6' => '1',
                                              'net.ipv6.conf.default.disable_ipv6' => '1' })
        end

        def ensure_adapter(record, state)
          expected = record.dig('peer', 'adapter_id')
          resource = runtime.inspect_service(identity(record), expected_id: expected)
          verify_definition!(record, resource) if resource
          # The random per-instance token and adapter identity were persisted with the lease.
          resource ||= runtime.create_service(adapter_definition(record))
          record.fetch('peer')['adapter_id'] = resource.fetch('id')
          store.write(state)
          resource
        end

        def verify_definition!(record, resource)
          return if resource.dig('labels', 'io.empeira.definition') == adapter_definition(record).fingerprint

          raise Providers::OwnershipError, 'Unexpected peer adapter definition'
        end

        def packet_command(record)
          ['docker', 'exec', '-i', record.fetch('peer').fetch('adapter_id'), '/adapter', 'tap', tap(record), 'peerbr']
        end

        def validate_exposure!(resource)
          unless resource && resource.fetch('networks').keys == [network_name] && resource.fetch('ports').empty? &&
                 resource.fetch('published_ports').values.all?(&:nil?)
            raise Providers::OwnershipError, 'Peer helper has unexpected network or port exposure'
          end
        end

        def attach_bridge(resource)
          result = runtime.service_exec(resource, %w[/adapter bridge peerbr eth0])
          raise Error, 'Cannot attach the Docker peer adapter bridge' unless result.success?
        end

        def binary_digest(resource)
          result = runtime.service_exec(resource, %w[/adapter sha256])
          digest = result.stdout.strip
          return digest if result.success? && digest.match?(/\A[0-9a-f]{64}\z/)

          raise Error, 'Cannot verify peer adapter binary integrity'
        end

        def verify_adapter(record)
          resource = runtime.inspect_service(identity(record), expected_id: record.dig('peer', 'adapter_id'))
          validate_exposure!(resource)
          HelperSecurity.verify!(resource, privileged_tap: key == 'DockerAdapter')
          digest = binary_digest(resource)
          expected = record.dig('peer', 'helper_sha256')
          raise Providers::OwnershipError, 'Peer helper checksum changed' if expected && expected != digest

          record.fetch('peer')['helper_sha256'] = digest
        end
      end
    end
  end
end
