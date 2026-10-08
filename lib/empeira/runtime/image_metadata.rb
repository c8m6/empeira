# frozen_string_literal: true

module Empeira
  module Runtime
    # Native CLIs own registry authentication, manifest negotiation and transport.
    module ImageMetadata
      def with_image_updates
        previous = @image_metadata
        @image_metadata = {}
        yield
      ensure
        @image_metadata = previous
      end

      def remote_digest(image)
        return @image_metadata.fetch(image) if @image_metadata&.key?(image)

        digest = platform_digest(remote_descriptors(image))
        @image_metadata[image] = digest if @image_metadata
        digest
      rescue Error => e
        raise Providers::ExecutionError, "Image metadata check failed for #{image}: #{e.message}", cause: nil
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Validate descriptor shape, platform and unambiguous digest together.
      def platform_digest(descriptors)
        unless descriptors.is_a?(Array) && descriptors.all?(Hash)
          raise Providers::ExecutionError, 'Runtime returned malformed image descriptors'
        end

        selected = descriptors.select { |entry| matching_platform?(entry['platform']) }
        digests = selected.map { |entry| entry['digest'] }.uniq
        unless digests.size == 1 && valid_digest?(digests.first)
          raise Providers::ExecutionError, "No unambiguous Linux/#{architecture} manifest digest in runtime metadata"
        end

        digests.first
      end

      def matching_platform?(platform)
        return false unless platform.is_a?(Hash)

        platform['os'] == 'linux' && platform['architecture'] == architecture &&
          (platform['variant'].to_s.empty? || (architecture == 'arm64' && platform['variant'] == 'v8'))
      end

      def valid_digest?(value)
        value.is_a?(String) && value.match?(Images::Configuration::DIGEST)
      end

      def metadata_command(arguments, image:, timeout: 30)
        update_command(arguments, operation: 'remote image metadata', timeout: timeout, registry: image)
      end

      def local_image(image)
        result = runner.run(name, arguments: ['image', 'inspect', image], timeout: 30)
        return unless result.success?

        data = parse_json(result.stdout)
        malformed! unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
        data.first
      end

      def local_digests(data)
        [data['Digest'], *Array(data['RepoDigests']).map { |value| value.to_s.split('@', 2)[1] }]
          .select { |digest| valid_digest?(digest) }.uniq
      end

      def same_remote_image?(image, local, remote)
        return false unless local && local['Architecture'] == architecture && local['Os'] == 'linux'

        digests = local_digests(local)
        return true if digests.include?(remote)

        # Docker's classic store can record an index digest. Resolve that immutable
        # historical reference natively before comparing platform manifests.
        digests.any? { |digest| remote_digest(Images::Reference.pinned(image, digest)) == remote }
      end
    end
  end
end
