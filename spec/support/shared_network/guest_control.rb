# frozen_string_literal: true

module SharedNetworkProof
  module GuestControl
    private

    def read_response(id)
      loop do
        line = @serial.gets
        raise Failure, "#{name} console closed" unless line

        response = parse_response(line)
        next unless response.is_a?(Hash) && response['id'] == id

        raise Failure, "#{name}: #{response['error']}" unless response['ok']

        return response
      end
    end

    def parse_response(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil # Linux boot logs are not JSON.
    end

    def qmp(socket, operation)
      socket.puts(JSON.generate(execute: operation))
      loop do
        reply = JSON.parse(socket.gets)
        raise Failure, reply['error'].to_s if reply['error']
        return reply['return'] if reply.key?('return')
      end
    end

    def quit_owned_process
      Timeout.timeout(5) do
        UNIXSocket.open(path('qmp.sock')) do |socket|
          JSON.parse(socket.gets).fetch('QMP')
          qmp(socket, 'qmp_capabilities')
          actual = qmp(socket, 'query-name').fetch('name')
          raise Failure, "#{name} QEMU ownership mismatch" unless actual == process_name

          qmp(socket, 'quit')
        end
      end
    end

    def live_process?(pid)
      File.read("/proc/#{pid}/stat").split[2] != 'Z'
    rescue Errno::ENOENT
      false
    end
  end
end
