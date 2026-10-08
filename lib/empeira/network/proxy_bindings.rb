# frozen_string_literal: true

module Empeira
  module Network
    class ProxyBindings
      def initialize(context:, resources:, network:, nodes:)
        @context = context
        @resources = resources
        @network = network
        @nodes = nodes
        @config = context.configuration.fetch('proxy')
      end

      def configuration
        entries = %w[server].map do |name|
          rules(name.tr('-', '_'), address(name), @config.fetch('global'))
        end
        @nodes.sort.each_with_index do |(hostname, record), index|
          entries << node_rules(hostname, record, index)
        end
        "#{entries.compact.join("\n")}\n"
      end

      private

      def node_rules(hostname, record, index)
        return if record['network_phase'] == 'bootstrap'

        domains = HostPolicy.new(@config).resolve(hostname)
        rules("node_#{index}", address(hostname), domains)
      end

      def address(name)
        @resources[name]&.dig('networks', @network, 'IPAddress')
      end

      def rules(name, address, domains, authorization = nil)
        return unless address && !address.empty? && !domains.empty?

        IPAddr.new(address)
        entries = ["acl #{name}_source src #{address}"]
        condition = "#{name}_source"
        if authorization
          entries << "acl #{name}_identity req_header Proxy-Authorization " \
                     "^Basic[[:space:]]#{Regexp.escape(authorization)}$"
          condition += " #{name}_identity"
        end
        entries.concat(ProxyPolicy.domain_rules(domains, name: "#{name}_domains", condition: condition)).join("\n")
      end
    end
  end
end
