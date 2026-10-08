# frozen_string_literal: true

module SharedNetworkProof
  # Explicit software-emulated artifact diagnostic. It cannot validate Podman, TAP, KVM or host isolation.
  class SocketGuest < Guest
    def initialize(socket:, listen:, **)
      super(**)
      @socket = socket
      @listen = listen
    end

    private

    def launch
      @commands.run('qemu-system-x86_64', *arguments)
    end

    def accelerator
      'tcg'
    end

    def cpu
      'max'
    end

    def network_argument
      "stream,id=peer,server=#{@listen ? 'on' : 'off'},addr.type=unix,addr.path=#{@socket}"
    end
  end
end
