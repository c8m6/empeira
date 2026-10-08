# frozen_string_literal: true

module Empeira
  module Runtime
    module RegistryDiagnostics
      private

      def registry_failure_hint(image, diagnostic, timed_out:)
        host = Images::Reference.host(image)
        case Execution::Diagnostics.registry_failure(diagnostic, timed_out: timed_out)
        when :auth
          "Registry authentication or authorization failed for #{host}. " \
          "Authenticate with the selected container runtime, check repository permissions and retry:\n  " \
          "#{name} login #{host}"
        when :missing then "Registry image or tag is unavailable: #{image}. Check the repository and tag."
        when :network then "Registry network access failed for #{host}. Check connectivity and DNS."
        when :tls then "Registry TLS verification failed for #{host}. Check the selected runtime's CA trust."
        else 'Check the selected runtime registry access and diagnostic below.'
        end
      end
    end
  end
end
