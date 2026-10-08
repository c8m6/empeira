# frozen_string_literal: true

require 'net/http'
require 'uri'

module Empeira
  module VM
    # Resolve moving upstream aliases to a content-addressed image before downloading.
    class ImageSource
      Image = Data.define(:identity, :url, :filename)
      UBUNTU = { '22.04' => 'jammy', '24.04' => 'noble' }.freeze
      ARCHITECTURES = { 'amd64' => 'x86_64', 'arm64' => 'aarch64' }.freeze

      def initialize(fetch_text: nil)
        @fetch_text = fetch_text || method(:read_text)
      end

      def resolve(distribution:, version:, architecture:)
        arch = architecture.to_s
        raise UnavailableFeature, 'VM image architecture must be amd64 or arm64' unless ARCHITECTURES.key?(arch)

        url, manifest = case distribution
                        when 'ubuntu' then ubuntu(version, arch)
                        when 'rocky' then rocky(version, arch)
                        else raise UnavailableFeature, "No verified VM image source for #{distribution} #{version}"
                        end
        filename = URI(url).path.split('/').last
        checksum = checksum_for(@fetch_text.call(manifest), filename)
        identity = Images::Identity.new(distribution: distribution, version: version, architecture: arch,
                                        source: url, revision: checksum, checksum: checksum)
        Image.new(identity: identity, url: url, filename: filename)
      end

      private

      def ubuntu(version, arch)
        codename = UBUNTU[version]
        raise UnavailableFeature, "Ubuntu #{version} VM image is not supported" unless codename

        base = "https://cloud-images.ubuntu.com/releases/#{codename}/release"
        ["#{base}/ubuntu-#{version}-server-cloudimg-#{arch}.img", "#{base}/SHA256SUMS"]
      end

      def rocky(version, arch)
        raise UnavailableFeature, "Rocky Linux #{version} VM image is not supported" unless %w[8 9].include?(version)

        arch_name = ARCHITECTURES.fetch(arch)
        base = "https://dl.rockylinux.org/pub/rocky/#{version}/images/#{arch_name}"
        image = "Rocky-#{version}-GenericCloud-Base.latest.#{arch_name}.qcow2"
        ["#{base}/#{image}", "#{base}/#{image}.CHECKSUM"]
      end

      def checksum_for(text, filename)
        escaped = Regexp.escape(filename)
        ubuntu = /\A([0-9a-f]{64}) \*?#{escaped}\s*\z/i
        rocky = /\ASHA256 \(#{escaped}\) = ([0-9a-f]{64})\s*\z/i
        text.each_line do |line|
          match = ubuntu.match(line)
          return match[1].downcase if match

          match = rocky.match(line)
          return match[1].downcase if match
        end
        raise Error, 'Upstream image checksum is missing or malformed'
      end

      def read_text(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.get(uri.request_uri)
        end
        raise Error, 'Cannot retrieve upstream VM image checksum' unless response.is_a?(Net::HTTPSuccess)
        raise Error, 'Upstream VM image checksum is too large' if response.body.bytesize > 100_000

        response.body
      rescue SocketError, IOError, SystemCallError, Timeout::Error
        raise Error, 'Cannot retrieve upstream VM image checksum', cause: nil
      end
    end
  end
end
