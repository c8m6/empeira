# frozen_string_literal: true

module Empeira
  module Network
    # Logical identities remain independent of runtime container names and addresses.
    class Naming
      DOMAIN = 'empeira.internal'

      def hostname(service)
        "#{service}.#{DOMAIN}"
      end

      def aliases(service)
        [service, hostname(service)]
      end

      def reserved(config)
        additional = config.dig('containers', 'additional').map { |entry| entry.fetch('name') }
        Configuration::AdditionalServices::RESERVED + additional
      end

      def no_proxy(additional = [])
        ['localhost', '127.0.0.1', '::1', ".#{DOMAIN}", 'server', 'puppetdb', 'postgres', 'dns', 'proxy',
         *additional].uniq.join(',')
      end
    end
  end
end
