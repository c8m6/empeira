# frozen_string_literal: true

require 'socket'
require 'io/wait'

RSpec.describe 'System SSH byte connector' do
  it 'relays independent concurrent connections and preserves half-close semantics' do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    upstream = Thread.new do
      Array.new(2) do
        socket = server.accept
        Thread.new(socket) do |client|
          client.write("reply:#{client.read}")
        ensure
          client.close
        end
      end.each(&:join)
    end
    helper = File.expand_path('../resources/network/ssh_connect.rb', __dir__)
    clients = 2.times.map do |index|
      Thread.new do
        Tempfile.create('connector-input') do |input|
          Tempfile.create('connector-output') do |output|
            input.write("request-#{index}")
            input.rewind
            arguments = index.zero? ? [helper, port.to_s] : [helper, '127.0.0.1', port.to_s]
            result = Empeira::Execution::Runner.new.stream(RbConfig.ruby, arguments: arguments,
                                                                          input: input, output: output)
            output.rewind
            expect(result).to be_success
            expect(output.read).to eq("reply:request-#{index}")
          end
        end
      end
    end
    Timeout.timeout(10) do
      clients.each(&:value)
      upstream.value
    end
  ensure
    server&.close
    clients&.each { |thread| thread.kill.join }
    upstream&.kill&.join
  end
  it 'rejects invalid guest ports before connecting' do
    helper = File.expand_path('../resources/network/ssh_connect.rb', __dir__)
    result = Empeira::Execution::Runner.new.run(RbConfig.ruby, arguments: [helper, '0'], timeout: 3)
    expect(result).not_to be_success
  end
end
