# frozen_string_literal: true

require 'socket'
require 'open3'

RSpec.describe 'Agent-independent container SSH byte transport', :files_only do
  def connector
    path = File.expand_path('../resources/nodes/ssh/connect.sh', __dir__)
    File.read(path).gsub('/opt/puppetlabs/puppet/bin/ruby', File.join(@directory, 'absent-agent-ruby'))
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
    Open3.popen3('/bin/bash', '-c', connector, 'ssh-transport', server.addr[1].to_s) do |input, output, error, process|
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
end
