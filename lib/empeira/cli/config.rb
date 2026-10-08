# frozen_string_literal: true

module Empeira
  module CLI
    class Config < Base
      desc 'show', 'Display the effective configuration'
      def show
        app = application
        data = Configuration::Display.redact(app.context.configuration)
        mounts = ControlPlane::Plan.new(context: app.context).hiera.entries
        data['effective_hiera_mounts'] = mounts unless mounts.empty?
        say YAML.dump(data)
      end

      desc 'validate', 'Validate the effective configuration'
      def validate
        application.context.configuration
        say 'Configuration is valid.'
      end
    end
  end
end
