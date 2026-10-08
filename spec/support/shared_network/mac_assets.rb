# frozen_string_literal: true

require_relative 'assets'

module SharedNetworkProof
  class MacAssets < Assets
    BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/netboot'
    # Official Alpine 3.24.2, kernel 6.18.52-0-virt, reviewed 2026-10-05 over HTTPS.
    DIGESTS = {
      'vmlinuz-virt' => 'e45e1f6083d1ed45db6647b422e32b6ae6dc54de7b8190b7b97744fb293412e3',
      'initramfs-virt' => 'ffe65ec5a0c0bf470042ad28f7ce7aa5f842ce8090e4230fb2703a7a34e1bebe'
    }.freeze

    def initialize(**)
      super
      @directory = File.join(@directory, 'aarch64')
    end

    def prepare
      super
      source = File.expand_path('../../../resources/network/adapter', __dir__)
      @commands.run('go', 'test', './...', directory: source, timeout: 120)
      environment = { 'CGO_ENABLED' => '0', 'GOOS' => 'linux', 'GOARCH' => 'arm64', 'GOTOOLCHAIN' => 'local' }
      @commands.run('go', 'build', '-trimpath', '-o', path('adapter'), '.', directory: source, timeout: 120,
                                                                            environment: environment)
      FileUtils.cp(File.join(SOURCE, 'transport', 'Containerfile'), path('Containerfile'))
      self
    end

    def image
      content = %w[probe adapter Containerfile].map { |name| File.binread(path(name)) }.join
      digest = Digest::SHA256.hexdigest(content)
      "localhost/empeira-macos-network-proof:#{digest}"
    end

    private

    def build_environment
      { 'GOARCH' => 'arm64' }
    end

    def init_content
      super.gsub('ttyS0', 'ttyAMA0').sub('exec /probe', "/bin/busybox echo EMPEIRA_PROOF_READY\nexec /probe")
    end
  end
end
