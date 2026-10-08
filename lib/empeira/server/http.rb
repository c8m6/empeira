# frozen_string_literal: true

module Empeira
  module Server
    module HTTP
      def self.arguments
        ['curl', '--silent', '--fail', '--max-time', '8', '--noproxy', '*']
      end

      def self.tls_arguments
        ssl = '/etc/puppetlabs/puppet/ssl'
        [*arguments, '--cacert', "#{ssl}/certs/ca.pem", '--cert', "#{ssl}/certs/server.empeira.internal.pem",
         '--key', "#{ssl}/private_keys/server.empeira.internal.pem"]
      end
    end
  end
end
