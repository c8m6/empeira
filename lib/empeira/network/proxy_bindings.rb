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
        entries = bindings.filter_map do |label, hostname, domains|
          rules(label, address(hostname), domains)
        end
        "#{entries.join("\n")}\n"
      end

      def addresses
        bindings.filter_map { |_, hostname, _| address(hostname) }.uniq
      end

      private

      def bindings
        infrastructure_bindings + node_bindings
      end

      def infrastructure_bindings
        scope = @config.fetch('infrastructure')
        return [] unless scope.fetch('enabled')

        names = %w[server postgres puppetdb-backend puppetdb] +
                @context.configuration.dig('containers', 'additional').map { |service| service.fetch('name') }
        names.map { |name| [name.tr('-', '_'), name, scope.fetch('allow')] }
      end

      def node_bindings
        scope = @config.fetch('nodes')
        return [] unless scope.fetch('enabled')

        policy = HostPolicy.new(scope)
        @nodes.sort.each_with_index.filter_map do |(hostname, record), index|
          ["node_#{index}", hostname, policy.resolve(hostname)] unless record['network_phase'] == 'bootstrap'
        end
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
