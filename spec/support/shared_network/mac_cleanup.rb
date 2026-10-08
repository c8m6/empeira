# frozen_string_literal: true

module SharedNetworkProof
  module MacCleanup
    def cleanup
      guests.each_value(&:stop)
      errors = stop_channels
      remove_resources
      unless errors.empty?
        raise Failure,
              "Packet failures; resources removed, logs retained in #{directory}: #{errors.join('; ')}"
      end

      FileUtils.remove_entry_secure(directory)
      puts 'PASS macOS cleanup: owned HVF guests, packet endpoints, containers, network and sockets removed'
    end

    private

    def remove_resources
      %w[containers networks].each do |kind|
        @intents.fetch(kind).keys.reverse_each { |name| remove_owned(kind, name) }
      end
    end

    def stop_channels
      errors = []
      @channels.each_value do |channel|
        channel.stop
      rescue Failure => e
        raise unless channel.stopped?

        errors << e.message
      end
      errors
    end
  end
end
