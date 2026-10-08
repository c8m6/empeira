# frozen_string_literal: true

require_relative 'guest'

module SharedNetworkProof
  class MacGuest < Guest
    def initialize(socket:, **)
      super(**)
      @socket = socket
    end

    def arguments
      super.map { |value| value.gsub('ttyS0', 'ttyAMA0').gsub(' quiet ', ' earlycon=pl011,0x9000000 ') }.tap do |args|
        args[args.index('-machine') + 1] = 'virt,gic-version=3'
        args[args.index('-m') + 1] = '512'
      end
    end

    private

    def launch
      @commands.run('qemu-system-aarch64', *arguments, '-S')
      @serial = UNIXSocket.new(path('serial.sock'))
      UNIXSocket.open(path('qmp.sock')) do |socket|
        JSON.parse(socket.gets).fetch('QMP')
        qmp(socket, 'qmp_capabilities')
        qmp(socket, 'cont')
      end
      wait_console
    end

    def wait_console
      Timeout.timeout(20) do
        loop do
          line = @serial.gets
          raise Failure, "#{name} closed during boot" unless line
          break if line.strip == 'EMPEIRA_PROOF_READY'
        end
      end
    end

    def accelerator
      'hvf'
    end

    def network_argument
      "stream,id=peer,server=off,addr.type=unix,addr.path=#{@socket}"
    end

    def live_process?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end
