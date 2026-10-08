# frozen_string_literal: true

require 'socket'
require 'zlib'
require 'stringio'
require 'rubygems/package'

# Synthetic HTTP Git and Forge sources: no production repositories or public downloads.
class ModuleSource
  attr_reader :requests, :commit

  def initialize(directory)
    @directory = Pathname(directory).join('source')
    @directory.mkpath
    @requests = []
    prepare_git
    prepare_forge
  end

  def start
    @server = TCPServer.new('127.0.0.1', 0)
    @thread = Thread.new do
      loop do
        socket = @server.accept
        serve(socket)
      ensure
        socket&.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    self
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def close
    @server&.close
    @thread&.join
  end

  def prepare_git
    git('init', '--quiet', '--initial-branch=fixture', @directory.to_s)
    @directory.join('value.txt').write('synthetic Git module')
    git('-C', @directory.to_s, 'add', 'value.txt')
    git('-C', @directory.to_s, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '--quiet', '-m', 'Synthetic fixture')
    git('-C', @directory.to_s, 'tag', 'v1')
    git('-C', @directory.to_s, 'update-server-info')
    @commit = git('-C', @directory.to_s, 'rev-parse', 'HEAD').strip
  end

  def git(*arguments)
    result = Empeira::Execution::Runner.new.run('git', arguments: arguments)
    raise result.stderr unless result.success?

    result.stdout
  end

  def prepare_forge
    files = { 'metadata.json' => JSON.generate('name' => 'fixture-sample', 'version' => '1.0.0',
                                               'license' => 'AGPL-3.0-only', 'dependencies' => []),
              'manifests/init.pp' => 'class sample {}' }
    buffer = StringIO.new
    Gem::Package::TarWriter.new(buffer) do |tar|
      files.each do |name, content|
        tar.add_file_simple("fixture-sample-1.0.0/#{name}", 0o644, content.bytesize) { |io| io.write(content) }
      end
    end
    zipped = StringIO.new
    Zlib::GzipWriter.wrap(zipped) { |io| io.write(buffer.string) }
    @archive = zipped.string
  end

  def serve(socket)
    request = socket.gets
    return unless request

    path = request.split[1].split('?').first
    @requests << path
    loop { break if [nil, "\r\n"].include?(socket.gets) }
    body, type = response(path)
    status = body ? '200 OK' : '404 Not Found'
    body ||= 'missing'
    socket.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(body)
  end

  def response(path)
    return [@archive, 'application/octet-stream'] if path == '/files/fixture-sample-1.0.0.tar.gz'

    if %w[/v3/modules/fixture-sample /v3/releases/fixture-sample-1.0.0].include?(path)
      release = { 'slug' => 'fixture-sample-1.0.0', 'version' => '1.0.0',
                  'file_uri' => '/files/fixture-sample-1.0.0.tar.gz',
                  'file_sha256' => Digest::SHA256.hexdigest(@archive), 'file_md5' => Digest::MD5.hexdigest(@archive) }
      data = if path == '/v3/modules/fixture-sample'
               { 'slug' => 'fixture-sample',
                 'current_release' => release }
             else
               release
             end
      return [JSON.generate(data), 'application/json']
    end
    file = @directory.join('.git', path.delete_prefix('/fixture.git/'))
    [file.file? ? file.binread : nil, 'text/plain']
  end
end
