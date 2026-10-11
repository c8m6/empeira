# frozen_string_literal: true

module Empeira
  module CLI
    class Node < Base
      map 'run' => :run_node, 'shell' => :shell_node, 'exec' => :exec_node

      desc 'exec HOSTNAME -- COMMAND [ARGUMENTS...]', 'Run a root guest command without SSH or implicit shell parsing'
      option :timeout, type: :numeric, desc: 'Guest command timeout in seconds (default: unlimited)'
      def exec_node(hostname, *_arguments)
        arguments = @guest_arguments || []
        Empeira::Node::DiagnosticCommand.validate!(arguments, options[:timeout])
        result = application.nodes.exec(name: hostname, arguments: arguments, timeout: options[:timeout])
        if result.timed_out
          warn 'Guest command timed out; its process groups were stopped.'
          raise SystemExit, 124
        end
        raise SystemExit, result.exit_status
      end

      desc 'run HOSTNAME', 'Create a container or VM node and run its agent'
      option :provider, type: :string, default: 'container', enum: Empeira::Node.registry.names,
                        desc: 'Node provider (default: container)'
      option :os, type: :string, desc: 'Operating system'
      option :version, type: :string, desc: 'Operating system version'
      option :memory, type: :string, desc: 'Memory in MiB (positive integer)'
      option :cpus, type: :string, desc: 'CPU count (positive integer)'
      def run_node(hostname)
        progressing('Preparing node...', node: true) do |app|
          app.run_node(hostname: hostname, provider: options[:provider])
        end
      end

      desc 'ssh HOSTNAME', 'Open system SSH (VM: managed identity; container: local user authentication)'
      option :user, type: :string, desc: 'Remote login user (overrides personal SSH preferences)'
      option :identity, type: :string, desc: 'SSH identity file (VM default: managed key)'
      option :port, type: :string, desc: 'System SSH guest port (default: 22)'
      def ssh(hostname)
        result = application.nodes.ssh(name: hostname, user: options[:user], identity: options[:identity],
                                       port: ssh_port)
        raise SystemExit, result.exit_status unless result.success?
      end

      no_commands do
        def ssh_port
          return unless options[:port]

          Configuration::SSHPreferences.port!(Integer(options[:port], 10))
        rescue ArgumentError
          raise ConfigurationError, 'SSH port must be an integer from 1 to 65535'
        end
      end

      %w[start stop destroy shell console puppet logs].each do |operation|
        descriptions = { 'shell' => 'Open an interactive root terminal (runtime exec or VM VirtIO PTY)',
                         'console' => 'Attach to the private VM serial console; Ctrl+] detaches',
                         'destroy' => 'Remove an owned node without version or guest-access requirements' }
        desc "#{operation} HOSTNAME", descriptions.fetch(operation, "#{operation.capitalize} an existing node")
        if operation == 'destroy'
          option :project_path, type: :string,
                                desc: 'Former absolute Git root path for recovery without a control repository'
        end
        define_method(operation == 'shell' ? 'shell_node' : operation) do |hostname|
          if %w[shell console ssh logs].include?(operation)
            result = application.nodes.public_send(operation, name: hostname)
            raise SystemExit, result.exit_status if operation == 'ssh' && !result.success?
            raise Error, "Node #{operation} failed" unless result.success?
          else
            progressing("#{operation.capitalize} node...", recovery: operation == 'destroy') do |app|
              app.nodes.public_send(operation, name: hostname)
            end
          end
        end
      end

      desc 'list', 'List workspace nodes and observed runtime state'
      def list
        rows = application.nodes.list
        say 'HOSTNAME PROVIDER RUNTIME OS/VERSION STATE PUPPET_EXIT NETWORK'
        rows.each do |row|
          say [row['hostname'], row['provider'], row['runtime'], "#{row['os']}/#{row['version']}",
               row['state'], row['last_puppet_exit'] || '-', row['network'] || '-'].join(' ')
        end
      end
    end
  end
end
