# frozen_string_literal: true

require 'fileutils'

module Empeira
  module Server
    # Export only the CA-issued service identity needed by the owned relay.
    class RelayCertificate
      NAME = 'puppetdb.empeira.internal'
      SSL = '/etc/puppetlabs/puppet/ssl'

      def initialize(context:)
        @directory = context.locations.workspace(context.workspace).join('puppetdb-relay')
      end

      def path(name)
        @directory.join(name).to_s
      end

      def prepare(runtime:, server:)
        raise Error, 'Relay certificate directory is an unsafe symlink' if @directory.symlink?
        return if File.file?(path('cert.pem')) && File.file?(path('key.pem'))

        reject_partial_identity!

        FileUtils.mkdir_p(@directory, mode: 0o700)
        File.chmod(0o700, @directory)
        issue(runtime, server)
        export(runtime, server)
      ensure
        remove_files(%w[cert.pem.pending key.pem.pending]) unless @directory.symlink?
      end

      def issue(runtime, server)
        result = runtime.service_exec(server, [Node::Certificates::CA, 'ca', 'generate', '--certname', NAME],
                                      timeout: 60)
        raise Error, 'Puppet CA could not issue the relay certificate; inspect server logs' unless result.success?
      end

      def export(runtime, server)
        { 'cert.pem' => "#{SSL}/certs/#{NAME}.pem",
          'key.pem' => "#{SSL}/private_keys/#{NAME}.pem" }.each do |name, source|
          temporary = path("#{name}.pending")
          runtime.copy_from(server, source, temporary)
          File.chmod(name == 'key.pem' ? 0o600 : 0o644, temporary)
          File.rename(temporary, path(name))
        end
      end

      def reject_partial_identity!
        return unless File.exist?(path('cert.pem')) || File.exist?(path('key.pem'))

        raise Error, 'PuppetDB relay certificate is incomplete; restore or destroy the workspace'
      end

      def cleanup
        raise Error, 'Relay certificate directory is an unsafe symlink' if @directory.symlink?
        return unless @directory.directory?

        remove_files(%w[cert.pem key.pem cert.pem.pending key.pem.pending])
        @directory.rmdir if @directory.children.empty?
      end

      private

      def remove_files(names)
        names.each do |name|
          file = path(name)
          File.unlink(file) if File.exist?(file) || File.symlink?(file)
        end
      rescue SystemCallError
        raise Error, 'Cannot remove owned relay certificate files; cleanup is incomplete'
      end
    end
  end
end
