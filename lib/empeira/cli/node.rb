# frozen_string_literal: true

module Empeira
  module CLI
    class Node < Base
      map 'run' => :run_node, 'shell' => :shell_node

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

      %w[start stop destroy shell puppet logs].each do |operation|
        desc "#{operation} HOSTNAME", "#{operation.capitalize} an existing node"
        define_method(operation == 'shell' ? 'shell_node' : operation) do |hostname|
          if %w[shell ssh logs].include?(operation)
            result = application.nodes.public_send(operation, name: hostname)
            raise SystemExit, result.exit_status if operation == 'ssh' && !result.success?
            raise Error, "Node #{operation} failed" unless result.success?
          else
            progressing("#{operation.capitalize} node...") { |app| app.nodes.public_send(operation, name: hostname) }
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
