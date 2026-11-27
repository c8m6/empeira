# frozen_string_literal: true

require 'socket'
require 'open3'
require 'timeout'

RSpec.describe 'Agent-independent container SSH byte transport', :files_only do
  def connector
    path = File.expand_path('../resources/nodes/ssh/connect.sh', __dir__)
    File.read(path).gsub('/opt/puppetlabs/puppet/bin/ruby', File.join(@directory, 'absent-agent-ruby'))
  end

  def with_connector(port, &block)
    Open3.popen3('/bin/bash', '-c', connector, 'ssh-transport', port.to_s, pgroup: true) do |*streams|
      block.call(*streams)
    ensure
      process = streams.last
      if process.alive?
        Process.kill('TERM', -process.pid)
        Process.kill('KILL', -process.pid) unless process.join(5)
      end
    end
  end

  it 'preserves binary bytes before the agent exists and exits when the server closes' do
    server = TCPServer.new('127.0.0.1', 0)
    payload = (0..255).to_a.pack('C*') * 128
    receiver = Thread.new do
      socket = server.accept
      begin
        request = socket.read(payload.bytesize)
        socket.write(request.reverse)
      ensure
        socket.close
      end
    end
    with_connector(server.addr[1]) do |input, output, error, process|
      input.binmode.write(payload)
      # Keep stdin open: remote EOF alone must terminate both relay children.
      expect(Timeout.timeout(5) { output.binmode.read }).to eq(payload.reverse)
      expect(Timeout.timeout(5) { process.value.exitstatus }).to eq(0)
      expect(error.read).to be_empty
    end
    receiver.value
  ensure
    server&.close
    receiver&.kill
  end

  it 'exits when local input closes while the server keeps the connection open' do
    server = TCPServer.new('127.0.0.1', 0)
    receiver = Thread.new do
      socket = server.accept
      begin
        socket.read
      ensure
        socket.close
      end
    end
    with_connector(server.addr[1]) do |input, output, error, process|
      input.close
      expect(Timeout.timeout(5) { process.value.exitstatus }).to eq(0)
      expect(output.read).to be_empty
      expect(error.read).to be_empty
    end
    expect(Timeout.timeout(5) { receiver.value }).to eq('')
  ensure
    server&.close
    receiver&.kill
  end

  it 'reaps the relay children when terminated with both streams still open' do
    server = TCPServer.new('127.0.0.1', 0)
    with_connector(server.addr[1]) do |input, output, error, process|
      socket = Timeout.timeout(5) { server.accept }
      input.write('ready')
      input.flush
      expect(Timeout.timeout(5) { socket.read(5) }).to eq('ready')
      Process.kill('TERM', process.pid)
      expect(Timeout.timeout(5) { process.value.exitstatus }).to eq(143)
      expect(Timeout.timeout(5) { output.read }).to be_empty
      expect(Timeout.timeout(5) { socket.read }).to eq('')
      expect(error.read).to be_empty
    ensure
      socket&.close
    end
  ensure
    server&.close
  end
end
