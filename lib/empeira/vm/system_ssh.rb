# frozen_string_literal: true

module Empeira
  module VM
    # Direct peer transport; system login never invokes the privileged management channel.
    class SystemSSH
      def initialize(context:, runner:, runtime:, qemu:, store: Infrastructure::Store.new(context: context))
        @context = context
        @runner = runner
        @qemu = qemu
        @store = store
        @peer = Network::Peer::Backend.build(context: context, runner: runner, runtime: runtime,
                                             store: store)
      end

      def session(record, user: nil, identity: nil, port: nil)
        client, endpoint = prepare(record, user: user, identity: identity, port: port)
        client.session(endpoint, user: user, identity: identity)
      end

      def prepare(record, user: nil, identity: nil, port: nil)
        selected = Configuration::SSHPreferences.port!(port || 22)
        raise Error, 'Recorded VM is not running; system SSH refused' unless @qemu.running?(record)

        proxy = @peer.system_ssh_command(record, port: selected)
        endpoint = record.merge('ssh_port' => selected)
        client = client_for(record, proxy)
        prepare = -> { client.prepare(endpoint, user: user, identity: identity) }
        @store.operation ? @store.operation.node_phase(&prepare) : prepare.call
        [client, endpoint]
      end

      private

      def client_for(record, proxy)
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'), purpose: :system,
                                               instance: Node::Inventory.instance(record))
        Node::UserSSH.new(runner: @runner, credentials: credentials, proxy_command: proxy,
                          default_user: CloudInit::USER, managed_identity: true,
                          home: @context.locations.home)
      end
    end
  end
end
