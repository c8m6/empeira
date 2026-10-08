# frozen_string_literal: true

module Empeira
  module ControlPlane
    # A fixed TCP UI relay publishes HTTPS without giving Chromium an egress attachment.
    class Browser
      def initialize(plan)
        @plan = plan
      end

      def definitions(dns: nil)
        { 'browser' => browser(dns), 'browser-ui' => gateway(dns) }
      end

      def browser(dns)
        Services::Definition.new(key: 'browser', workspace: @plan.context.workspace,
                                 hostname: @plan.naming.hostname('browser'), network: @plan.network, dns: dns,
                                 image: Images::Configuration.reference(@plan.config.dig('browser', 'image'),
                                                                        registry: @plan.config.dig('images',
                                                                                                   'registry')),
                                 memory: 2048, cpus: 2, shm_size: '1g',
                                 mounts: ['type=tmpfs,dst=/config'],
                                 environment: { 'CHROME_CLI' => @plan.config.dig('browser', 'start_url'),
                                                'http_proxy' => '', 'https_proxy' => '', 'all_proxy' => '',
                                                'HTTP_PROXY' => '', 'HTTPS_PROXY' => '', 'ALL_PROXY' => '' })
      end

      # rubocop:disable-next Metrics/AbcSize -- Fixed relay options stay auditable together.
      def gateway(dns)
        relay = Pathname(__dir__).join('../../../resources/browser/relay.rb').realpath
        access = Network::Egress.new(workspace: @plan.context.workspace, policy: Network::Policy.new)
        Services::Definition.new(key: 'browser-ui', workspace: @plan.context.workspace,
                                 hostname: @plan.naming.hostname('browser-ui'), network: access.backend_name, dns: dns,
                                 **relay_image, memory: 96, cpus: 1,
                                 entrypoint: 'ruby', command: ['/empeira-browser/relay.rb'],
                                 configuration: File.read(relay),
                                 sysctls: { 'net.ipv4.ip_forward' => '0' },
                                 mounts: [@plan.bind(relay, '/empeira-browser/relay.rb'),
                                          @plan.bind(@plan.files.path('browser-address'),
                                                     '/empeira-browser/address')],
                                 ports: ['127.0.0.1::3001/tcp'])
      end

      def relay_image
        Images::Configuration.artifact(
          @plan.config.dig('images', 'relay'), purpose: 'relay', registry: @plan.config.dig('images', 'registry')
        )
      end

      # rubocop:disable-next Metrics/AbcSize -- Compare both configured and observed publications.
      def self.valid_ports?(resource)
        configured = resource.fetch('ports')
        published = resource.fetch('published_ports', {}).compact
        return false unless configured.keys == ['3001/tcp']
        return false unless published.keys == ['3001/tcp'] || resource['state'] != 'running'

        requested = configured['3001/tcp']
        return false unless Node::SSHEndpoint.loopback_binding?(requested)
        return true unless resource['state'] == 'running'

        actual = published['3001/tcp']
        Node::SSHEndpoint.binding?(actual, nil) &&
          ['', '0', actual.first['HostPort']].include?(requested.first['HostPort'])
      end

      def self.url(resource)
        raise Providers::OwnershipError, 'Browser UI must publish only HTTPS on loopback' unless valid_ports?(resource)

        "https://127.0.0.1:#{resource.fetch('published_ports').fetch('3001/tcp').first.fetch('HostPort')}/"
      end
    end
  end
end
