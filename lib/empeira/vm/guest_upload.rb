# frozen_string_literal: true

module Empeira
  module VM
    # Integrity-pinned binary uploads are atomically published by the guest adapter.
    class GuestUpload
      def initialize(channel)
        @channel = channel
      end

      def write(file, destination, mode:)
        @channel.send_frame('type' => 'upload')
        ready!
        digest = write_chunks(file)
        @channel.send_frame('type' => 'install', 'destination' => destination, 'mode' => mode,
                            'sha256' => digest.hexdigest)
        result = GuestOutput.new.consume(@channel, timeout: 35)
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: 'VM upload', tool: 'VirtIO management')
        raise Error, "VM upload failed; staging cleaned up, VM retained\n#{details}", cause: nil
      end

      private

      def write_chunks(file)
        digest = OpenSSL::Digest.new('SHA256')
        while (chunk = file.read(GuestChannel::CHUNK))
          digest.update(chunk)
          @channel.send_frame('type' => 'chunk', 'data' => Base64.strict_encode64(chunk))
          ready!
        end
        digest
      end

      def ready!
        return if @channel.receive(timeout: 30)['type'] == 'ready'

        raise Error, 'VM upload protocol did not acknowledge staging'
      end
    end
  end
end
