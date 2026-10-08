# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class LinuxPodman < Backend
        def preflight(state)
          super
          info = JSON.parse(command('podman', '--remote=false', 'info', '--format', 'json'))
          unless info.dig('host', 'security', 'rootless') && info.dig('host', 'networkBackend') == 'netavark'
            raise Error, 'VM peer networking requires local rootless Podman/Netavark; no rootful fallback'
          end

          namespace('test', '-r', '/dev/net/tun')
          namespace('test', '-w', '/dev/net/tun')
          namespace('test', '-r', '/dev/kvm')
          namespace('test', '-w', '/dev/kvm')
          verify_forwarding
        end

        def prepare(record, _state)
          check_record(record)
          links = JSON.parse(namespace('ip', '-j', 'link', 'show'))
          raise Providers::OwnershipError, 'VM TAP already exists; inspect its owning process' if
            links.any? { |link| link['ifname'] == tap(record) }
        end

        def arguments(record)
          ['-netdev', "tap,id=peer,ifname=#{tap(record)},script=no,downscript=no",
           '-device', "virtio-net-pci,netdev=peer,mac=#{record.fetch('mac_address')}"]
        end

        def launch(executable, arguments)
          namespace(executable, *arguments)
        end

        def connect(record, _state)
          # QEMU owns the nonpersistent TAP FD. Closing it removes the interface.
          namespace('ip', 'link', 'set', 'dev', tap(record), 'alias', record.fetch('peer').fetch('token'))
          namespace('ip', 'link', 'set', 'dev', tap(record), 'master', bridge)
          namespace('ip', 'link', 'set', 'dev', tap(record), 'up')
          verify_forwarding
        end

        def stop(record)
          links = JSON.parse(namespace('ip', '-j', 'link', 'show'))
          return unless links.any? { |link| link['ifname'] == tap(record) }

          raise Error, 'VM TAP is still present after shutdown; refusing to release the node lease'
        end

        def destroy(record, _state)
          stop(record)
        end

        def healthy?(record)
          health([record]).fetch(record.fetch('hostname'))
        end

        def health(records)
          return {} if records.empty?

          links = JSON.parse(namespace('ip', '-j', 'link', 'show', timeout: 2))
          records.to_h { |record| [record.fetch('hostname'), attached?(record, links)] }
        rescue Error, JSON::ParserError
          records.to_h { |record| [record.fetch('hostname'), false] }
        end

        def management_port
          Integer(namespace(RbConfig.ruby, '-rsocket', '-e',
                            "TCPServer.open('127.0.0.1',0) { |s| puts s.addr[1] }"))
        end

        def ssh_command(record)
          helper = Pathname(__dir__).join('../../../../resources/network/ssh_connect.rb').realpath
          ['podman', '--remote=false', 'unshare', '--rootless-netns', RbConfig.ruby, helper.to_s,
           record.fetch('ssh_port').to_s]
        end

        private

        def namespace(*, **)
          command('podman', '--remote=false', 'unshare', '--rootless-netns', *, **)
        end

        def attached?(record, links)
          links.any? do |link|
            link['ifname'] == tap(record) && link['ifalias'] == record.dig('peer', 'token') &&
              link['master'] == bridge && link.fetch('flags', []).include?('UP')
          end
        end

        def verify_forwarding
          return if namespace('cat', "/proc/sys/net/ipv4/conf/#{bridge}/forwarding").strip == '0'

          raise Error, 'Peer bridge routing is enabled; refusing VM attachment'
        end
      end
    end
  end
end
