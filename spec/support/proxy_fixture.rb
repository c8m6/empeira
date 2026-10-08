# frozen_string_literal: true

require 'openssl'

# Dedicated synthetic upstream on an RFC 2544 benchmarking subnet.
# No public Internet service or production certificate participates in these tests.
class ProxyFixture
  attr_reader :dns_address, :ca_path

  def initialize(app:, runtime:, directory:)
    @app = app
    @runtime = runtime
    @directory = Pathname.new(directory).join('proxy-fixture')
    FileUtils.mkdir_p(@directory)
    @subnet = "198.18.#{SecureRandom.random_number(240) + 1}"
    @dns_address = "#{@subnet}.3"
    @egress = Empeira::Network::Egress.new(workspace: app.context.workspace, policy: Empeira::Network::Policy.new)
    @resources = []
  end

  def start
    prepare_certificate
    prepare_files
    execute(['network', 'create', '--driver', 'bridge', '--subnet', "#{@subnet}.0/24",
             *@egress.labels.flat_map { |key, value| ['--label', "#{key}=#{value}"] }, @egress.backend_name])
    images = @app.context.configuration.fetch('images')
    start_service('fixture-dns', Empeira::Images::Configuration.reference(images.fetch('dns')), "#{@subnet}.3",
                  command: ['-conf', '/fixture/Corefile'])
    server_image = Empeira::Images::Configuration.reference(images.fetch('server'),
                                                            registry: images['registry'])
    start_service('fixture-web', server_image, "#{@subnet}.2",
                  entrypoint: Empeira::ControlPlane::Health::RUBY, command: ['/fixture/server.rb'])
  end

  def stop
    @resources.reverse_each do |definition, resource|
      @runtime.remove_service(definition, expected_id: resource.fetch('id'))
    end
  end

  private

  def start_service(key, image, address, **)
    @runtime.ensure_image(image)
    definition = Empeira::Services::Definition.new(key: key, workspace: @app.context.workspace,
                                                   network: @egress.backend_name, memory: 64, image: image, user: '0',
                                                   mounts: ["type=bind,src=#{@directory},dst=/fixture,readonly"], **)
    arguments = @runtime.send(:create_service_arguments, definition)
    arguments.insert(1, '--ip', address)
    execute(arguments)
    resource = @runtime.inspect_service(definition)
    @resources << [definition, resource]
    @runtime.start_service(resource)
  end

  def execute(arguments)
    result = @app.runner.run(@app.context.container_engine, arguments: arguments, timeout: 60)
    raise 'Synthetic proxy fixture failed to start' unless result.success?
  end

  # Keep this isolated synthetic certificate generation readable as one sequence.
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
  def prepare_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse('/CN=allowed.test')
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension('subjectAltName', 'DNS:allowed.test'))
    certificate.add_extension(extensions.create_extension('basicConstraints', 'CA:TRUE', true))
    certificate.sign(key, OpenSSL::Digest.new('SHA256'))
    File.write(@directory.join('key.pem'), key.to_pem, perm: 0o600)
    File.write(@directory.join('cert.pem'), certificate.to_pem)
    @ca_path = @app.context.project.path.join('fixture-ca.pem')
    File.write(ca_path, certificate.to_pem)
  end

  def prepare_files
    resolvers = Empeira::Platform::Resolvers.new(platform: @app.context.platform, runner: @app.runner)
                                            .resolve('mode' => 'host', 'servers' => [])
    File.write(@directory.join('Corefile'), ".:53 {\n hosts /fixture/hosts {\n  fallthrough\n }\n " \
                                            "forward . #{resolvers.join(' ')}\n}\n")
    File.write(@directory.join('hosts'),
               "#{@subnet}.2 allowed.test denied.test\n127.0.0.1 private.test\n169.254.169.254 metadata.test\n")
    File.write(@directory.join('server.rb'), server_code)
  end

  def server_code
    <<~'RUBY'
      require 'socket'
      require 'openssl'
      context = OpenSSL::SSL::SSLContext.new
      context.cert = OpenSSL::X509::Certificate.new(File.read('/fixture/cert.pem'))
      context.key = OpenSSL::PKey.read(File.read('/fixture/key.pem'))
      servers = [TCPServer.new('0.0.0.0', 80),
                 OpenSSL::SSL::SSLServer.new(TCPServer.new('0.0.0.0', 443), context)]
      servers.map do |server|
        Thread.new do
          loop do
            begin
              client = server.accept
              while (line = client.gets) && line != "\r\n"; end
              client.write("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture")
            rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
              nil
            ensure
              client&.close
            end
          end
        end
      end.each(&:join)
    RUBY
  end
end
