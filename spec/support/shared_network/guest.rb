# frozen_string_literal: true

require 'securerandom'
require_relative 'guest_control'

module SharedNetworkProof
  class Guest
    include GuestControl

    attr_reader :name, :ip, :mac, :tap

    def initialize(commands:, assets:, directory:, identity:)
      @commands = commands
      @assets = assets
      @directory = directory
      @name, @ip, @mac, @tap, @token = identity.values_at(:name, :ip, :mac, :tap, :token)
    end

    def start
      launch
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          info = request(op: 'info')
          return info if info['tcp']
        rescue Failure, SystemCallError, IOError
          # The guest boot log precedes the JSON control protocol.
        end
        sleep 0.2
      end
      log = File.file?(path('serial.log')) ? File.binread(path('serial.log')).byteslice(-4000, 4000) : nil
      raise Failure, "#{name} did not boot; serial log: #{log}"
    end

    def request(**operation)
      id = SecureRandom.hex(8)
      Timeout.timeout(5) do
        @serial ||= UNIXSocket.new(path('serial.sock'))
        @serial.puts(JSON.generate(operation.merge(id: id)))
        read_response(id)
      end
    rescue Timeout::Error
      raise Failure, "#{name} probe timed out"
    end

    def stop
      @serial&.close
      @serial = nil
      return unless control_present?

      pid = Integer(File.read(path('pid')).strip)
      quit_owned_process
      Timeout.timeout(10) { sleep 0.1 while live_process?(pid) }
      %w[pid qmp.sock serial.sock].each { |file| FileUtils.rm_f(path(file)) }
    end

    def arguments
      ['-name', process_name, '-machine', 'q35', '-accel', accelerator, '-cpu', cpu, '-m', '192', '-smp', '1',
       '-nodefaults', '-display', 'none', '-no-reboot', '-daemonize', '-pidfile', path('pid'),
       '-qmp', "unix:#{path('qmp.sock')},server=on,wait=off",
       '-chardev', "socket,id=serial,path=#{path('serial.sock')},server=on,wait=off,logfile=#{path('serial.log')}",
       '-serial', 'chardev:serial', '-kernel', @assets.path('vmlinuz-virt'), '-initrd', @assets.path('guest.cpio'),
       '-append', "console=ttyS0 quiet panic=-1 net.ifnames=0 ipv6.disable=1 proof.ip=#{ip} proof.name=#{name}",
       '-netdev', network_argument, '-device', "virtio-net-pci,netdev=peer,mac=#{mac}"]
    end

    private

    def control_present?
      return false unless File.exist?(path('pid')) || File.socket?(path('qmp.sock'))
      return true if File.socket?(path('qmp.sock'))

      raise Failure, "#{name} QMP socket missing; refusing unverified shutdown"
    end

    def launch
      @commands.namespace('qemu-system-x86_64', *arguments)
    end

    def accelerator
      'kvm'
    end

    def cpu
      'host'
    end

    def network_argument
      "tap,id=peer,ifname=#{tap},script=no,downscript=no"
    end

    def process_name
      "empeira-proof-#{@token}-#{name}"
    end

    def path(file)
      File.join(@directory, "#{name}-#{file}")
    end
  end
end
