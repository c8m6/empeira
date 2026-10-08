# frozen_string_literal: true

module Empeira
  module Node
    # The sole allowed container-node publication is managed SSH on host loopback.
    class SSHEndpoint
      def self.valid?(resource, record)
        return resource.fetch('ports').empty? unless record['ssh_host']
        return false unless record['ssh_host'] == '127.0.0.1'
        return tunnel?(resource, record) if record['ssh_transport'] == 'tunnel'

        loopback?(resource, record)
      end

      def self.tunnel?(resource, record)
        resource.fetch('ports').empty? && resource.fetch('published_ports', {}).values.all?(&:nil?) &&
          record.dig('definition', 'ports') == [] && record['ssh_port'] == 22
      end

      # rubocop:disable-next Metrics/AbcSize -- Compare configured and observed ports against the recorded endpoint.
      def self.loopback?(resource, record)
        return false unless managed?(record) && resource.fetch('ports').keys == ['22/tcp']

        bindings = resource.fetch('ports')['22/tcp']
        return false unless binding?(bindings, record['ssh_port'], pending: record['ssh_port'].nil?)
        return true unless resource['state'] == 'running'

        publications = resource.fetch('published_ports', {})
        publications.keys == ['22/tcp'] && binding?(publications['22/tcp'], record['ssh_port'])
      end

      def self.managed?(record)
        record['ssh_host'] == '127.0.0.1' && record.dig('definition', 'ports') == ['127.0.0.1::22/tcp']
      end

      def self.binding?(bindings, port, pending: false)
        return false unless loopback_binding?(bindings)

        value = bindings[0]['HostPort']
        return true if pending && value == ''

        valid_port?(value) && (port.nil? || value.to_i == port)
      end

      def self.loopback_binding?(bindings)
        bindings.is_a?(Array) && bindings.size == 1 && bindings[0]['HostIp'] == '127.0.0.1'
      end

      def self.valid_port?(value)
        value.is_a?(String) && value.match?(/\A[0-9]+\z/) && value.to_i.between?(1, 65_535)
      end

      def self.port(resource)
        Integer(resource.fetch('published_ports').fetch('22/tcp').first.fetch('HostPort'), 10)
      end
    end
  end
end
