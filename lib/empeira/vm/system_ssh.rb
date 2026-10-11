# frozen_string_literal: true

module Empeira
  module VM
    # Direct peer transport; system login never invokes the privileged management channel.
    class SystemSSH
      def initialize(context:, runner:, runtime:, qemu:)
        @context = context
        @runner = runner
        @qemu = qemu
        @peer = Network::Peer::Backend.build(context: context, runner: runner, runtime: runtime,
                                             store: Infrastructure::Store.new(context: context))
      end

      def session(record, user: nil, identity: nil, port: nil)
        selected = Configuration::SSHPreferences.port!(port || 22)
        raise Error, 'Recorded VM is not running; system SSH refused' unless @qemu.running?(record)

        proxy = @peer.system_ssh_command(record, port: selected)
        endpoint = record.merge('ssh_port' => selected)
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'), purpose: :system)
        Node::UserSSH.new(runner: @runner, credentials: credentials, proxy_command: proxy,
                          default_user: CloudInit::USER, managed_identity: true,
                          home: @context.locations.home).session(endpoint, user: user, identity: identity)
      end
    end
  end
end
