# frozen_string_literal: true

module ProductionPeerChecks
  def prepare_peer_endpoints
    script = File.read(File.join(__dir__, 'peer_endpoint.rb'))
    %w[container-peer vm-one vm-two server echo-service browser-role].each do |name|
      next if name == 'vm-two' && !peer_state.fetch('nodes').key?(name)

      peer_ruby(name, script)
      next if %w[server echo-service browser-role].include?(name)

      verify_peer_catalog(name)
    end
  end

  # rubocop:disable-next Metrics/AbcSize -- Compare both observed runtime bindings with the persisted instance lease.
  def verify_container_lease
    record = peer_state.fetch('nodes').fetch('container-peer')
    definition = Empeira::Node::Definition.new(hostname: 'container-peer', workspace: peer_app.context.workspace)
    resource = @peer_runtime.inspect_service(definition, expected_id: record.fetch('id'))
    network = Empeira::ControlPlane::Plan.new(context: peer_app.context).network
    expect(resource.dig('networks', network, 'IPAddress')).to eq(record.dig('definition', 'ip'))
    expect(resource.dig('networks', network, 'MacAddress')).to eq(record.dig('definition', 'mac_address'))
  end

  def verify_peer_catalog(name)
    result = peer_command(name, %w[cat /var/lib/peer-provider])
    expect(result).to be_success, result.stderr
    expect(result.stdout).to eq(name.start_with?('vm-') ? 'vm' : 'container')
  end

  def peer_matrix
    [%w[container-peer vm-one], %w[vm-one container-peer], %w[vm-one vm-two],
     %w[vm-two vm-one], %w[server vm-one], %w[echo-service vm-one], %w[vm-one echo-service],
     %w[browser-role vm-one]].each do |source, destination|
      %w[tcp udp].each do |protocol|
        code = if protocol == 'tcp'
                 's=TCPSocket.new(ARGV[0],24681);s.write("peer");abort unless s.read(4)=="peer"'
               else
                 's=UDPSocket.new;s.connect(ARGV[0],24682);s.send("peer",0);' \
                   'abort unless IO.select([s],nil,nil,3);abort unless s.recv(4)=="peer"'
               end
        peer_ruby(source, code, "#{destination}.empeira.internal")
        puts "PASS production #{source} -> #{destination} #{protocol.upcase}"
      end
    end
    peer_http
  end

  def peer_http
    code = 's=TCPSocket.new(ARGV[0],24683);s.write("GET / HTTP/1.0\r\n\r\n");' \
           'abort unless s.read.include?("peer-http")'
    peer_ruby('browser-role', code, 'vm-one.empeira.internal')
  end

  def verify_responding_canary
    definition = Empeira::Services::Definition.new(key: 'fixture-web', workspace: peer_app.context.workspace)
    resource = @peer_runtime.inspect_service(definition)
    code = 's=TCPSocket.new(ARGV[0],80);s.write("GET / HTTP/1.0\r\n\r\n");' \
           'abort unless s.read.include?("fixture")'
    result = @peer_runtime.service_exec(resource,
                                        [Empeira::Node::Certificates::RUBY, '-rsocket', '-e', code, canary_ip])
    expect(result).to be_success, result.stderr
  end

  def canary_ip
    @peer_canary.dns_address.sub(/\.3\z/, '.2')
  end

  def force_guest_route(name)
    return unless name.start_with?('vm-')

    layout = Empeira::Network::Peer::Layout.new(peer_state.fetch('peer_network').fetch('subnet'))
    result = peer_command(name, ['ip', 'route', 'replace', 'default', 'via', layout.address(1), 'dev', 'eth0'])
    expect(result).to be_success, result.stderr
  end

  def peer_dns_and_isolation
    verify_responding_canary
    %w[container-peer vm-one vm-two].each do |name|
      %w[container-peer vm-one vm-two server].each do |target|
        peer_ruby(name, 'abort if Addrinfo.getaddrinfo(ARGV[0],nil,:INET).empty?', "#{target}.empeira.internal")
      end
      force_guest_route(name)
      [canary_ip, '1.1.1.1'].each do |destination|
        code = 'begin; Socket.tcp(ARGV[0],80,connect_timeout:2) { abort "unexpected egress" };' \
               'rescue SystemCallError,IOError; end'
        peer_ruby(name, code, destination)
      end
      puts "PASS production #{name} DNS and direct egress denial"
    end
  end
end
