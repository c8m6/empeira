# frozen_string_literal: true

module Empeira
  module Node
    module VMPreflight
      private

      def preflight_vm(request)
        reject_vm_name!(request.hostname.downcase)
        ::Empeira::VM::Interfaces.validate_static!(context, request.hostname, @state)
        accelerator = @engine.preflight!(progress: @progress)
        @progress.stage(15, 'Validating guest image and bootstrap requirements...')
        validate_bootstrap(request)
        image = @source.resolve(distribution: request.os, version: request.version,
                                architecture: context.platform.architecture)
        [image, accelerator]
      end

      def validate_bootstrap(request)
        @cloud.validate!
        packages = preflight_packages(request)
        @requirements = ::Empeira::VM::BootstrapRequirements.new(context: context, os: request.os,
                                                                 version: request.version,
                                                                 distribution_required: packages.required?)
        ::Empeira::Agent::Acquisition.new(context: context, runtime: @runtime).preflight!(@requirements)
        @peer.preflight(@state)
        @bootstrap_proxy.preflight!(@state) if @requirements.destinations.any?
        @progress.heartbeat(@requirements.report)
      end

      def preflight_packages(request)
        PackageBootstrap.new(config: context.configuration.dig('bootstrap', 'packages'),
                             os: request.os, execute: nil)
      end
    end
  end
end
