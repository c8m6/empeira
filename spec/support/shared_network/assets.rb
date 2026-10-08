# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'zlib'

module SharedNetworkProof
  # Linux initramfs accepts concatenated cpio archives, with the later /init replacing the distribution init.
  module Archive
    def self.entry(name, content, mode:, inode: 1)
      fields = [inode, mode, 0, 0, 1, 0, content.bytesize, 0, 0, 0, 0, name.bytesize + 1, 0]
      header = "070701#{fields.map { |n| format('%08x', n) }.join}#{name}\0"
      align(header, 4) + align(content, 4)
    end

    def self.align(data, boundary)
      data + ("\0" * (-data.bytesize % boundary))
    end

    def self.overlay(init:, probe:)
      data = entry('init', init, mode: 0o100755) + entry('probe', probe, mode: 0o100755, inode: 2) +
             entry('TRAILER!!!', '', mode: 0, inode: 3)
      align(data, 512)
    end
  end

  class Assets
    SOURCE = File.expand_path(__dir__)
    BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/netboot'
    # Alpine 3.24.2 netboot observed 2026-10-03, kernel 6.18.52-0-virt. Refuse changed artifacts.
    DIGESTS = {
      'vmlinuz-virt' => '40f620bc8c93d952e57dd8dfc0f94fca1759d192a4fc4a260705d50ca378559c',
      'initramfs-virt' => 'c990c63e4602aa84b92d7df54fd180cb0e56590d61b71221ba6d60e913d26357'
    }.freeze

    attr_reader :directory

    def initialize(commands: Commands.new)
      @commands = commands
      cache = ENV.fetch('XDG_CACHE_HOME', File.join(Dir.home, '.cache'))
      @directory = File.join(cache, 'empeira', 'shared-network-proof')
    end

    def prepare
      FileUtils.mkdir_p(directory, mode: 0o700)
      self.class::DIGESTS.each { |name, digest| download(name, digest) }
      build_probe
      write_initramfs
      File.write(path('Containerfile'), "FROM scratch\nCOPY probe /probe\nENTRYPOINT [\"/probe\"]\n")
      self
    end

    def path(name)
      File.join(directory, name)
    end

    def image
      "localhost/empeira-network-proof:#{Digest::SHA256.file(path('probe')).hexdigest}"
    end

    private

    def write_initramfs
      File.binwrite(path('guest.cpio'), File.binread(path('initramfs-virt')) +
                    Zlib.gzip(Archive.overlay(init: init_content,
                                              probe: File.binread(path('probe')))))
    end

    def build_probe
      @commands.run('go', 'test', './...', directory: File.join(SOURCE, 'agent'), timeout: 120,
                                           environment: { 'GOTOOLCHAIN' => 'local' })
      @commands.run('go', 'build', '-buildvcs=false', '-trimpath', '-ldflags=-s -w', '-o', path('probe'), '.',
                    directory: File.join(SOURCE, 'agent'), timeout: 120,
                    environment: { 'CGO_ENABLED' => '0', 'GOOS' => 'linux', 'GOARCH' => 'amd64',
                                   'GOTOOLCHAIN' => 'local' }.merge(build_environment))
    end

    def build_environment
      {}
    end

    def init_content
      File.binread(File.join(SOURCE, 'init'))
    end

    def download(name, digest)
      destination = path(name)
      return if File.file?(destination) && Digest::SHA256.file(destination).hexdigest == digest

      temporary = "#{destination}.part"
      @commands.run('curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '90',
                    '--output', temporary, "#{self.class::BASE}/#{name}", timeout: 100)
      unless Digest::SHA256.file(temporary).hexdigest == digest
        raise Failure,
              "#{name} checksum mismatch; reviewed proof assets need updating"
      end

      File.rename(temporary, destination)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end
  end
end
