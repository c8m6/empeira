# frozen_string_literal: true

module Empeira
  module Node
    class Certificates
      PUPPET = '/opt/puppetlabs/bin/puppet'
      CA = '/opt/puppetlabs/bin/puppetserver'
      RUBY = '/opt/puppetlabs/puppet/bin/ruby'

      def initialize(runtime:, server:)
        @runtime = runtime
        @server = server
      end

      def enroll(node, record)
        name = record.fetch('hostname')
        raise Error, 'A CA identity already exists for this hostname; refusing to adopt it' if entry(name)

        install_ca(node)
        execute(node, [PUPPET, 'ssl', 'generate_request'], 'Node key preparation')
        fingerprint = public_key(node, "/etc/puppetlabs/puppet/ssl/certificate_requests/#{name}.pem", request: true)
        record['certificate_key'] = fingerprint
        yield
        execute(node, [PUPPET, 'ssl', 'submit_request'], 'Node certificate request')
        request = entry(name)
        unless request && fingerprint == ca_key(name, request: true)
          raise Error, 'CA request does not match the Empeira-owned node key; signing refused'
        end

        execute(@server, [CA, 'ca', 'sign', '--certname', name], 'Node certificate signing')
        execute(node, [PUPPET, 'ssl', 'download_cert'], 'Node certificate retrieval')
      end

      def clean(record)
        certificate = entry(record.fetch('hostname'))
        return unless certificate

        request = certificate.fetch('state') == 'requested'
        unless record['certificate_key'] && record['certificate_key'] == ca_key(record.fetch('hostname'),
                                                                                request: request)
          raise Error, 'CA identity differs from the recorded node key; certificate cleanup refused'
        end

        execute(@server, [CA, 'ca', 'clean', '--certname', record.fetch('hostname')], 'Node certificate cleanup')
      end

      private

      def entry(name)
        result = execute(@server, [CA, 'ca', 'list', '--all', '--format', 'json'], 'CA inventory')
        data = JSON.parse(result.stdout)
        data.values.flatten.find { |item| item.fetch('name') == name }
      rescue JSON::ParserError, NoMethodError, KeyError
        raise Error, 'Malformed CA inventory; certificate mutation refused', cause: nil
      end

      def ca_key(name, request:)
        directory = request ? 'requests' : 'signed'
        public_key(@server, "/etc/puppetlabs/puppetserver/ca/#{directory}/#{name}.pem", request: request)
      end

      def public_key(resource, path, request:)
        type = request ? 'Request' : 'Certificate'
        code = "require 'openssl'; require 'digest'; cert = OpenSSL::X509::#{type}.new(File.read(ARGV[0])); print Digest::SHA256.hexdigest(cert.public_key.to_der)"
        execute(resource, [RUBY, '-e', code, path], 'Certificate identity verification').stdout
      end

      def install_ca(node)
        Dir.mktmpdir('empeira-ca-') do |directory|
          file = File.join(directory, 'ca.pem')
          @runtime.copy_from(@server, '/etc/puppetlabs/puppet/ssl/certs/ca.pem', file)
          execute(node, ['mkdir', '-p', '/etc/puppetlabs/puppet/ssl/certs'], 'Node CA directory')
          @runtime.copy_to(node, file, '/etc/puppetlabs/puppet/ssl/certs/ca.pem')
        end
      end

      def execute(resource, arguments, operation)
        result = @runtime.service_exec(resource, arguments, timeout: 60)
        raise Error, "#{operation} failed; node state retained for diagnosis" unless result.success?

        result
      end
    end
  end
end
