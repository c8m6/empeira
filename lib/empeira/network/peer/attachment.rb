# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class Attachment
        def initialize(backend:, record:, state:)
          @backend = backend
          @record = record
          @state = state
        end

        def arguments
          @backend.arguments(@record) + Management.new(@record).arguments
        end

        def launch(executable, arguments)
          @backend.launch(executable, arguments)
        end

        def connect
          @backend.connect(@record, @state)
        end
      end

      # Only SSH uses SLIRP. Puppet, DNS, proxy and application traffic use the peer NIC.
      class Management
        def initialize(record)
          @record = record
        end

        def mac
          bytes = @record.fetch('mac_address').split(':')
          bytes[1] = '55'
          bytes.join(':')
        end

        def arguments
          port = @record.fetch('ssh_port')
          VM::Management.validate!(@record)
          target = "#{VM::Management::ADDRESS}:#{VM::Management::PORT}"
          ['-netdev', "user,id=management,restrict=on,ipv6=off,hostfwd=tcp:127.0.0.1:#{port}-#{target}",
           '-device', "virtio-net-pci,netdev=management,mac=#{mac}"]
        end
      end
    end
  end
end
