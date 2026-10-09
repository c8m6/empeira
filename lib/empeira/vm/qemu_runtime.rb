# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'socket'
require 'timeout'

module Empeira
  module VM
    # QEMU process control is a replaceable VM-engine concern.
    # rubocop:disable-next Metrics/ClassLength -- Launch and ownership-safe monitor control form one engine boundary.
    class QemuRuntime
      def initialize(engine:, runner:, context:)
        @engine = engine
        @runner = runner
        @context = context
      end

      def launch(record:, overlay:, seed:, network:)
        hostname = record.fetch('hostname')
        monitor = monitor_path(hostname)
        ensure_launchable_monitor!(record, monitor)
        execute_launch(record, overlay, seed, network, monitor)
      end

      def running?(record)
        monitor = monitor_path(record.fetch('hostname'))
        return false unless monitor.socket?

        Timeout.timeout(2) do
          UNIXSocket.open(monitor) do |socket|
            read_monitor_prompt(socket)
            verify_monitor_identity!(socket, record)
            true
          end
        end
      rescue SystemCallError, IOError, Timeout::Error
        false
      end

      def observed_running?(record)
        process_alive?(record) && monitor_path(record.fetch('hostname')).socket?
      end

      def stop(record)
        unless running?(record)
          raise Error, 'QEMU process is alive but monitor is unavailable; VM disk retained' if process_alive?(record)

          return nil
        end

        monitor_command(record, 'system_powerdown')
        wait_for_shutdown(record)
        if running?(record)
          monitor_command(record, 'quit')
          wait_for_shutdown(record, seconds: 5)
        end
        raise Error, 'QEMU did not stop; VM overlay retained' if running?(record)

        File.unlink(monitor_path(record.fetch('hostname'))) if monitor_path(record.fetch('hostname')).exist?
        record
      end

      def cleanup(record)
        raise Error, 'QEMU process is still alive; monitor state retained' if process_alive?(record)

        directory = monitor_directory(record.fetch('hostname'))
        return unless directory.exist? || directory.symlink?

        validate_monitor_directory!(directory)
        unlink_monitor_socket(directory.join('monitor.sock'))
        unlink_monitor_socket(directory.join('console.sock'))
        Dir.rmdir(directory)
      end

      def process_alive?(record)
        pid = record['pid']
        return false unless pid.is_a?(Integer) && pid.positive?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def serial_log(hostname)
        node_directory(hostname).join('serial.log')
      end

      def console(record)
        raise Error, 'VM is stopped; start it before attaching the console' unless running?(record)

        path = console_path(record.fetch('hostname'))
        validate_monitor_directory!(path.dirname)
        metadata = path.lstat
        unless metadata.socket? && metadata.uid == Process.uid
          raise Providers::OwnershipError, 'VM console endpoint ownership is invalid'
        end

        @runner.console(path, guidance: console_guidance(record.fetch('hostname')))
      rescue Errno::ENOENT
        raise Error, 'VM console endpoint is missing'
      end

      def console_path(hostname)
        monitor_directory(hostname).join('console.sock')
      end

      private

      def console_guidance(hostname)
        message = "Connected to VM serial console.\nPress Ctrl+] to detach. The VM will keep running.\n"
        return message if @context.configuration.dig('vm', 'console', 'root_password')

        "#{message}No console password is configured. Use empeira node ssh #{hostname} instead.\n"
      end

      def validate_monitor_directory!(directory)
        metadata = File.lstat(directory)
        return if metadata.directory? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise Error, 'VM monitor directory ownership changed; cleanup refused'
      end

      def unlink_monitor_socket(socket)
        return unless socket.exist? || socket.symlink?

        if socket.symlink? || !socket.lstat.socket? || socket.lstat.uid != Process.uid
          raise Error, 'Unexpected VM monitor path; cleanup refused'
        end

        File.unlink(socket) if socket.socket?
      end

      def ensure_launchable_monitor!(record, monitor)
        prepare_monitor_directory(record.fetch('hostname'))
        raise Error, 'Recorded QEMU process is still alive; refusing a second launch' if process_alive?(record)

        unlink_monitor_socket(console_path(record.fetch('hostname')))
        File.unlink(monitor) if monitor.socket? && !running?(record)
        raise Error, 'VM monitor already exists; inspect the recorded process first' if monitor.exist?
      end

      def execute_launch(record, overlay, seed, network, monitor)
        arguments = launch_arguments(record, overlay, seed, network.arguments, monitor)
        network.launch(@engine.executable, arguments)

        pid = Integer(File.read(pid_path(record.fetch('hostname'))).strip)
        record['pid'] = pid
        network.connect
        raise Error, 'QEMU did not create its monitor socket' unless monitor.socket?

        pid
      end

      def wait_for_shutdown(record, seconds: 30)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        while (running?(record) || process_alive?(record)) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.25
        end
      end

      def launch_arguments(record, overlay, seed, network, monitor)
        hostname = record.fetch('hostname')
        arch = @context.platform.architecture
        machine = arch == :arm64 ? 'virt' : 'q35'
        ['-name', process_name(record), '-machine', machine,
         '-accel', @engine.accelerator, '-cpu', 'host', '-m', record.fetch('memory').to_s,
         '-smp', record.fetch('cpus').to_s, '-display', 'none', '-daemonize',
         '-chardev', console_device(hostname), '-serial', 'chardev:console',
         '-pidfile', pid_path(hostname).to_s,
         '-monitor', "unix:#{escape(monitor)},server=on,wait=off",
         *boot_drives(overlay, seed), *firmware(arch), *network]
      end

      def console_device(hostname)
        "socket,id=console,path=#{escape(console_path(hostname))},server=on,wait=off," \
          "logfile=#{escape(serial_log(hostname))},logappend=on"
      end

      def boot_drives(overlay, seed)
        ['-drive', "file=#{escape(overlay)},if=virtio,format=qcow2,cache=none",
         '-drive', "file=#{escape(seed)},if=virtio,format=raw,readonly=on"]
      end

      def firmware(architecture)
        return [] unless architecture == :arm64

        ['-bios', @engine.firmware.to_s]
      end

      def escape(path)
        path.to_s.gsub(',', ',,')
      end

      def monitor_command(record, command)
        Timeout.timeout(3) do
          UNIXSocket.open(monitor_path(record.fetch('hostname'))) do |socket|
            read_monitor_prompt(socket)
            verify_monitor_identity!(socket, record)
            socket.write("#{command}\n")
            command == 'quit' ? wait_monitor_close(socket) : read_monitor_prompt(socket)
          end
        end
      rescue SystemCallError, IOError, Timeout::Error
        raise Error, 'Cannot control the recorded QEMU process', cause: nil
      end

      def process_name(record)
        "empeira-#{@context.workspace.id}-#{record.fetch('hostname')}-#{record.fetch('peer').fetch('token')}"
      end

      def verify_monitor_identity!(socket, record)
        socket.write("info name\n")
        return if read_monitor_prompt(socket).include?(process_name(record))

        raise Providers::OwnershipError, 'QEMU monitor belongs to a different node instance; control refused'
      end

      def wait_monitor_close(socket)
        loop { socket.readpartial(1024) }
      rescue EOFError
        nil
      end

      def read_monitor_prompt(socket)
        buffer = +''
        buffer << socket.readpartial(1024) until buffer.include?('(qemu)') || buffer.bytesize > 16_384
        raise Error, 'Unexpected QEMU monitor response' unless buffer.include?('(qemu)')

        buffer
      end

      def monitor_path(hostname)
        path = monitor_directory(hostname).join('monitor.sock')
        raise Error, 'Temporary path is too long for a QEMU monitor socket' if path.to_s.bytesize > 100

        path
      end

      def monitor_directory(hostname)
        identifier = Digest::SHA256.hexdigest("#{@context.workspace.id}:#{hostname}")[0, 24]
        [@context.locations.temporary, @context.locations.home].each do |root|
          directory = root.join("empeira-#{identifier}")
          return directory if directory.join('monitor.sock').to_s.bytesize <= 100
        end

        raise Error, 'No short private path is available for a QEMU monitor socket'
      end

      def prepare_monitor_directory(hostname)
        directory = monitor_directory(hostname)
        FileUtils.mkdir_p(directory, mode: 0o700)
        metadata = File.lstat(directory)
        return if metadata.directory? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)

        raise Error, 'VM monitor directory is not private to the current user'
      end

      def node_directory(hostname)
        @context.locations.workspace(@context.workspace).join('vms', hostname)
      end

      def pid_path(hostname)
        node_directory(hostname).join('qemu.pid')
      end
    end
  end
end
