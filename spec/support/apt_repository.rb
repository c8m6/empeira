# frozen_string_literal: true

require_relative 'http_fixture'

# A signed, synthetic APT repository with ephemeral keys and Basic authentication.
class APTRepositoryFixture
  attr_reader :http, :events, :package

  def initialize(runner:, directory:, address:, architecture:, credentials:)
    @runner = runner
    @directory = Pathname(directory).join('apt-fixture')
    @directory.mkpath
    @architecture = architecture
    @authorization = "Basic #{Base64.strict_encode64(credentials.join(':'))}"
    @events = []
    @package = 'synthetic agent package bytes'
    @packages = package_index
    @release = signed_release
    start_http(address)
    @origin = "https://#{address}:#{http.port}"
  end

  def source
    { 'url' => "#{@origin}/apt", 'suite' => 'noble', 'component' => 'main',
      'key' => { 'url' => "#{@origin}/signing-key", 'sha256' => Digest::SHA256.hexdigest(@key) } }
  end

  def close
    http&.close
    @runner.run('gpgconf', arguments: ['--homedir', @directory.join('gnupg').to_s, '--kill', 'gpg-agent'], timeout: 10)
  end

  private

  def start_http(address)
    @http = HTTPFixture.new(address: '0.0.0.0', addresses: [address]) do |request, headers|
      respond(request.split[1], headers['authorization'] == @authorization)
    end
  end

  def package_index
    <<~INDEX
      Package: synthetic-agent
      Version: 1.2.3-1
      Architecture: all
      Maintainer: Synthetic fixture <fixture@example.org>
      Filename: pool/agent.deb
      Size: #{@package.bytesize}
      SHA256: #{Digest::SHA256.hexdigest(@package)}
      Description: Synthetic package download fixture

    INDEX
  end

  def release_index
    <<~INDEX
      Origin: Empeira synthetic fixture
      Label: Empeira synthetic fixture
      Suite: noble
      Codename: noble
      Date: #{Time.now.utc.rfc2822}
      Architectures: #{@architecture}
      Components: main
      SHA256:
       #{Digest::SHA256.hexdigest(@packages)} #{@packages.bytesize} main/binary-#{@architecture}/Packages
    INDEX
  end

  def signed_release
    home = @directory.join('gnupg')
    home.mkdir(0o700)
    options = ['--no-options', '--homedir', home.to_s, '--batch', '--pinentry-mode', 'loopback', '--passphrase', '']
    command([*options, '--quick-generate-key', 'Empeira synthetic APT fixture <fixture@example.org>',
             'rsa2048', 'sign', '0'])
    @key = command([*options, '--armor', '--export']).stdout
    @directory.join('Release').write(release_index)
    command([*options, '--output', @directory.join('InRelease').to_s, '--clearsign', @directory.join('Release').to_s])
    @directory.join('InRelease').read
  end

  def command(arguments)
    result = @runner.run('gpg', arguments: arguments, timeout: 30)
    raise 'Cannot generate the synthetic APT signing fixture; gpg is required' unless result.success?

    result
  end

  def respond(path, authenticated)
    return ['200', 'OK', @key] if path == '/signing-key'

    body = { '/apt/dists/noble/InRelease' => @release,
             "/apt/dists/noble/main/binary-#{@architecture}/Packages" => @packages,
             '/apt/pool/agent.deb' => @package }[path]
    code = body ? '200' : '404'
    code = '401' unless authenticated
    @events << { path: path, authenticated: authenticated, code: code }
    reason = { '200' => 'OK', '401' => 'Unauthorized', '404' => 'Not Found' }.fetch(code)
    [code, reason, code == '200' ? body : 'Synthetic repository request denied']
  end
end
