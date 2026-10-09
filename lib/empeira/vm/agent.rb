# frozen_string_literal: true

module Empeira
  module VM
    # Guest package installation uses only the existing allowlisted HTTP/HTTPS proxy.
    class Agent
      PUPPET = Node::Certificates::PUPPET

      def initialize(context:, ssh:, runtime: nil, progress: Progress.new)
        @context = context
        @ssh = ssh
        @runtime = runtime
        @progress = progress
      end

      def ensure_installed(record, requirements: nil, proxy_url: nil)
        requirements ||= BootstrapRequirements.new(context: @context, os: record.fetch('os'),
                                                   version: record.fetch('version'),
                                                   architecture: record.fetch('architecture'))
        unless requirements.required?
          return if @ssh.run(record, [PUPPET, '--version']).success?

          raise Error,
                'No usable agent was found and managed bootstrap is unavailable; check bootstrap.guests metadata'
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

      def install_selected_agent(record, requirements)
        execute = ->(arguments) { @ssh.run(record, arguments, timeout: 300) }
        copy = ->(source, destination, mode) { @ssh.copy_to(record, source, destination, mode: mode) }
        @runtime ||= Runtime.registry.build(@context.container_engine, context: @context, runner: Execution::Runner.new)
        installer = Node::AgentInstaller.build(context: @context, runtime: @runtime, requirements: requirements,
                                               execute: execute, copy: copy, progress: @progress)
        installer.install(proxy_url: proxy_url)
        execute!(record, [PUPPET, '--version'], 'VM Puppet agent verification')
      end

      def execute!(record, arguments, operation)
        result = @ssh.run(record, arguments, timeout: 300)
        return if result.success?

        raise Error,
              "#{operation} failed (exit=#{result.exit_status}, timeout=#{result.timed_out}); VM retained for diagnosis"
      end
    end
  end
end
