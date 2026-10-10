# frozen_string_literal: true

module Empeira
  module VM
    # User preferences affect only the system daemon; the tunnel uses private management credentials.
    class SystemSSH
      def initialize(context:, runner:, management:)
        @context = context
        @runner = runner
        @management = management
      end

      def session(record, user: nil, identity: nil, port: nil)
        selected = Configuration::SSHPreferences.port!(port || 22)
        Management.validate!(record)
        proxy = @management.system_proxy_command(record, port: selected)
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
