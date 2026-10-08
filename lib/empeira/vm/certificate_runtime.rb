# frozen_string_literal: true

module Empeira
  module VM
    # Reuse the same targeted CA enrollment rules as container nodes.
    class CertificateRuntime
      def initialize(runtime:, ssh:, record:)
        @runtime = runtime
        @ssh = ssh
        @record = record
      end

      def service_exec(resource, arguments, timeout: 60)
        return @ssh.run(@record, arguments, timeout: timeout) if resource['vm']

        @runtime.service_exec(resource, arguments, timeout: timeout)
      end

      def copy_from(resource, source, destination)
        @runtime.copy_from(resource, source, destination)
      end

      def copy_to(resource, source, destination)
        return @ssh.copy_to(@record, source, destination) if resource['vm']

        @runtime.copy_to(resource, source, destination)
      end
    end
  end
end
