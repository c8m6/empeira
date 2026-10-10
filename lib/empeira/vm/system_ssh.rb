# frozen_string_literal: true

module Empeira
  module VM
    # User preferences affect only the system daemon; the tunnel uses private management credentials.
    class SystemSSH
      def initialize(context:, runner:, management:, peer:)
        @context = context
        @runner = runner
        @management = management
        @peer = peer
      end

      def session(record, user: nil, identity: nil, port: nil)
        selected = Configuration::SSHPreferences.port!(port || 22)
        separate = Management.separate?(record)
        if !separate && selected != 22
          raise Error,
                'Legacy VM SSH layout supports system port 22 only; recreate explicitly for separate management SSH'
        end

        proxy = separate ? @management.system_proxy_command(record, port: selected) : @peer.ssh_command(record)
        endpoint = separate ? record.merge('ssh_port' => selected) : record
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'), purpose: separate ? :system : nil)
        Node::UserSSH.new(runner: @runner, credentials: credentials, proxy_command: proxy,
                          default_user: CloudInit::USER, managed_identity: true,
                          home: @context.locations.home).session(endpoint, user: user, identity: identity)
      end
    end
  end
end
