# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'net/http'
require 'openssl'
require 'tempfile'
require 'uri'

module Empeira
  module VM
    # Base images are immutable and addressed by all source and checksum fields.
    class ImageCache
      def initialize(locations:, downloader: nil)
        @locations = locations
        @downloader = downloader || method(:download)
      end

      def fetch(image)
        directory = @locations.image(image.identity)
        FileUtils.mkdir_p(directory, mode: 0o700)
        destination = directory.join('base.qcow2')
        return destination if verified?(destination, image.identity.checksum)

        cache_image(image, directory, destination)
        destination
      rescue SystemCallError, IOError => e
        raise Error, "Cannot cache the verified VM image (#{e.class.name})", cause: nil
      end

      private

      def cache_image(image, directory, destination)
        Tempfile.create(['vm-image-', '.part'], directory) do |temporary|
          temporary.binmode
          @downloader.call(image.url, temporary)
          temporary.flush
          temporary.fsync
          raise Error, 'Downloaded VM image failed SHA-256 verification' unless
            verified?(temporary.path, image.identity.checksum)

          temporary.chmod(0o444)
          File.rename(temporary.path, destination)
        end
      end

      def verified?(path, checksum)
        File.file?(path) && !File.symlink?(path) && OpenSSL::Digest::SHA256.file(path).hexdigest == checksum
      end

      def download(url, file)
        received = nil
        uri = URI(url)
        raise Error, 'VM image source must use HTTPS' unless uri.is_a?(URI::HTTPS)

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) do |http|
          http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
            received = response
            validate_response!(response, url)
            response.read_body { |chunk| file.write(chunk) }
          end
        end
      rescue SocketError, OpenSSL::SSL::SSLError, IOError, SystemCallError, Timeout::Error, Net::ProtocolError => e
        diagnostic = Execution::Diagnostics.transport(operation: 'Download VM base image', url: url, error: e,
                                                      response: received)
        raise Error, "VM image download failed\n#{diagnostic}", cause: nil
      end

      def validate_response!(response, url)
        return if response.is_a?(Net::HTTPSuccess)

        diagnostic = Execution::Diagnostics.http_response(response, operation: 'Download VM base image', url: url)
        raise Error, "VM image download failed\n#{diagnostic}", cause: nil
      end
    end
  end
end
