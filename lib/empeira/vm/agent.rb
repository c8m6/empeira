# frozen_string_literal: true

module Empeira
  module VM
    # Guest package installation uses only the existing allowlisted HTTP/HTTPS proxy.
    class Agent
      PUPPET = Node::Certificates::PUPPET

      def initialize(context:, guest:, runtime: nil, progress: Progress.new)
        @context = context
        @guest = guest
        @runtime = runtime
        @progress = progress
      end

      def ensure_installed(record, requirements: nil, proxy_url: nil)
        requirements ||= BootstrapRequirements.new(context: @context, os: record.fetch('os'),
                                                   version: record.fetch('version'),
                                                   architecture: record.fetch('architecture'))
        unless requirements.required?
          verify_existing_agent!(record)
          return
        end
        raise Error, 'Managed agent installation requires the bootstrap proxy' unless proxy_url

        @proxy_url = proxy_url
        @requirements = requirements
        install_selected_agent(record, requirements)
      ensure
        @proxy_url = nil
      end

      private

      attr_reader :proxy_url

      def verify_existing_agent!(record)
        result = @guest.run(record, [PUPPET, '--version'])
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Existing VM Puppet agent verification',
                                                         tool: 'puppet')
        raise Error, 'No usable agent was found and managed bootstrap is unavailable; ' \
                     "check bootstrap.guests metadata\n#{details}", cause: nil
      end

      def install_selected_agent(record, requirements)
        execute = ->(arguments) { @guest.run(record, arguments, timeout: 300) }
        copy = ->(source, destination, mode) { @guest.copy_to(record, source, destination, mode: mode) }
        @runtime ||= Runtime.registry.build(@context.container_engine, context: @context, runner: Execution::Runner.new)
        installer = Node::AgentInstaller.build(context: @context, runtime: @runtime, requirements: requirements,
                                               execute: execute, copy: copy, progress: @progress)
        installer.install(proxy_url: proxy_url)
        execute!(record, [PUPPET, '--version'], 'VM Puppet agent verification')
      end

      def execute!(record, arguments, operation)
        result = @guest.run(record, arguments, timeout: 300)
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: operation, tool: arguments.first)
        raise Error, "#{operation} failed; VM retained for diagnosis\n#{details}", cause: nil
      end
    end
  end
end
