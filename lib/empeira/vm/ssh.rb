# frozen_string_literal: true

require 'securerandom'
require 'shellwords'

module Empeira
  module VM
    # Internal management transport for provisioning and Puppet operations.
    class SSH
      def initialize(context:, runner:, cloud_init:, executable_path: ENV.fetch('PATH', ''))
        @context = context
        @runner = runner
        @cloud_init = cloud_init
        @executable_path = executable_path
      end

      def run(record, arguments, timeout: 30)
        command = Shellwords.join(['sudo', '-n', *arguments])
        @runner.run(binary('ssh'), arguments: [*options(record), 'empeira@127.0.0.1', command], timeout: timeout)
      end

      def stream(record, arguments)
        command = Shellwords.join(['sudo', '-n', *arguments])
        @runner.stream(binary('ssh'), arguments: [*options(record), 'empeira@127.0.0.1', command])
      end

      def copy_to(record, source, destination, mode: '0644')
        temporary = "/home/empeira/.empeira-copy-#{SecureRandom.hex(8)}"
        transfer = @runner.run(binary('scp'), arguments: [*scp_options(record), source.to_s,
                                                          "empeira@127.0.0.1:#{temporary}"], timeout: 30)
        raise Error, 'Cannot copy a file into the VM' unless transfer.success?

        installed = run(record, ['install', '-m', mode, temporary, destination])
        raise Error, 'Cannot install a file in the VM' unless installed.success?
      ensure
        if temporary && !run(record, ['rm', '-f', '--', temporary]).success?
          raise Error, 'Cannot verify VM upload staging cleanup; VM retained for diagnosis'
        end
      end

      def wait(record, progress: nil, seconds: 300)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          return if run(record, ['cloud-init', 'status', '--wait'], timeout: 20).success?

          raise Error, 'VM SSH or cloud-init did not become ready; inspect serial log' if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          progress&.heartbeat('Waiting for VM network and cloud-init...')
          sleep 2
        end
      end

      private

      def client(record)
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'))
        backend = Network::Peer::Backend.build(context: @context, runner: @runner, runtime: nil, store: nil)
        Node::SSHClient.new(runner: @runner, credentials: credentials, user: 'empeira',
                            proxy_command: backend.ssh_command(record))
      end

      def options(record)
        client(record).options(record)
      end

      def scp_options(record)
        list = options(record)
        list[list.index('-p')] = '-P'
        list
      end

      def binary(name)
        @executable_path.split(File::PATH_SEPARATOR).each do |directory|
          path = Pathname(directory).join(name)
          return path.to_s if path.file? && path.executable?
        end
        raise UnavailableFeature, "#{name} is required for VM guest access"
      end
    end
  end
end
