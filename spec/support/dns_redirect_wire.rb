# frozen_string_literal: true

module DNSRedirectWire
  UPSTREAM = <<~'RUBY'
    require 'resolv'
    require 'socket'
    require 'json'
    def response(bytes, transport)
      query = Resolv::DNS::Message.decode(bytes)
      reply = Resolv::DNS::Message.new(query.id)
      reply.qr = 1
      reply.aa = 1
      reply.ra = 1
      reply.rd = query.rd
      query.question.each do |name, type|
        text = name.to_s
        File.open('/tmp/dns-requests', 'a') { |file| file.puts(JSON.generate(name: text, transport: transport)) }
        reply.add_question(name, type)
        if ['public.example.test', 'apps.corp.example.test', 'large.example.test'].include?(text)
          if text == 'large.example.test' && transport == 'udp'
            reply.tc = 1
          else
            count = text == 'large.example.test' ? 80 : 1
            count.times { |i| reply.add_answer(name, 30, Resolv::DNS::Resource::IN::A.new("192.0.2.#{i + 1}")) }
          end
        else
          reply.rcode = 3
        end
      end
      reply.encode
    end
    udp = UDPSocket.new
    udp.bind('0.0.0.0', 53)
    tcp = TCPServer.new('0.0.0.0', 53)
    threads = [Thread.new do
      loop do
        bytes, peer = udp.recvfrom(65535)
        udp.send(response(bytes, 'udp'), 0, peer[3], peer[1])
      end
    end, Thread.new do
      loop do
        client = tcp.accept
        Thread.new(client) do |socket|
          while (length = socket.read(2)) && length.bytesize == 2
            message = response(socket.read(length.unpack1('n')), 'tcp')
            socket.write([message.bytesize].pack('n') + message)
          end
        ensure
          socket.close
        end
      end
    end]
    threads.each(&:join)
  RUBY

  CLIENT = <<~RUBY
    require 'resolv'
    require 'socket'
    require 'timeout'
    require 'json'
    transport, host, name = ARGV
    query = Resolv::DNS::Message.new(rand(65536))
    query.rd = 1
    query.add_question(name, Resolv::DNS::Resource::IN::A)
    def request(transport, host, bytes)
      Timeout.timeout(3) do
        if transport == 'tcp'
          socket = TCPSocket.new(host, 53)
          socket.write([bytes.bytesize].pack('n') + bytes)
          socket.read(socket.read(2).unpack1('n'))
        else
          socket = UDPSocket.new
          socket.connect(host, 53)
          socket.send(bytes, 0)
          socket.recv(65535)
        end
      ensure
        socket&.close
      end
    end
    used = transport == 'auto' ? 'udp' : transport
    reply = Resolv::DNS::Message.decode(request(used, host, query.encode))
    if transport == 'auto' && reply.tc == 1
      used = 'tcp'
      reply = Resolv::DNS::Message.decode(request(used, host, query.encode))
    end
    raise 'Wrong DNS response identity' unless reply.id == query.id && reply.qr == 1
    puts JSON.generate(rcode: reply.rcode, tc: reply.tc, transport: used,
                       addresses: reply.answer.filter_map { |_, _, value| value.address.to_s if value.respond_to?(:address) })
  RUBY

  def dns_rules
    %w[udp tcp].map do |protocol|
      { 'from' => { 'ip' => '198.18.0.53', 'port' => 53, 'protocol' => protocol },
        'to' => { 'service' => 'coredns', 'port' => 53 } }
    end
  end

  def dns_query(transport, name, destination: '198.18.0.53')
    result = runtime.service_exec(server, [Empeira::Node::Certificates::RUBY, '-e', CLIENT,
                                           transport, destination, name], timeout: 10)
    expect(result).to be_success, result.stderr
    JSON.parse(result.stdout)
  end
end
