# frozen_string_literal: true

module Empeira
  module Network
    class Egress < Definition
      def identity
        "#{workspace.id}:egress"
      end

      def backend_name
        "empeira-#{workspace.id}-egress"
      end

      def ownership_labels
        super.merge('io.empeira.purpose' => 'proxy-egress-network')
      end

      def verify_isolation!(resource)
        raise UnsupportedPolicy, 'Proxy egress network unexpectedly isolated' unless resource && !resource.isolated
      end

      def to_h
        super.merge('policy' => { 'isolated' => false, 'proxy_only' => true })
      end
    end
  end
end
