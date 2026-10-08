# frozen_string_literal: true

module Empeira
  module Node
    class Image
      attr_reader :reference, :recipe, :build_files

      def initialize(config:, request:, architecture:)
        image = config.dig('images', 'nodes', request.os, request.version)
        raise ConfigurationError, 'node_defaults.os/version must select a configured images.nodes entry' unless image
        unless image.fetch('architectures', []).include?(architecture.to_s)
          raise Error, 'Node image does not support runtime architecture; configure images.nodes without emulation'
        end

        @build_files = {}
        @reference = Images::Configuration.reference(image, registry: config.dig('images', 'registry'))
        return if image['reference'] || !image['build']

        prepare_recipe(config, image)
        @reference = Images::Configuration.local_image(recipe, purpose: "node-#{architecture}")
      end

      private

      def prepare_recipe(config, image)
        root = Pathname(Images::Configuration::ROOT).join('nodes/ssh')
        @build_files = { 'node-start' => root.join('start').read, 'sshd_config' => root.join('sshd_config').read,
                         'node-connect' => root.join('../../network/ssh_connect.rb').read }
        @recipe = build_recipe(config, image) + "\n# SSH resources: #{Infrastructure::Definition.fingerprint(@build_files)}\n"
      end

      def build_recipe(config, image)
        template = Images::Configuration.recipe(image, registry: config.dig('images', 'registry'))
        template.gsub('@BASE_IMAGE@', reference)
      end
    end
  end
end
