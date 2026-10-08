# frozen_string_literal: true

module Empeira
  module Network
    module Peer
      class AdapterImage
        attr_reader :image, :recipe, :files

        # rubocop:disable-next Metrics/AbcSize -- Assemble the reviewed source and resolved builder identity together.
        def initialize(context:)
          root = Pathname(__dir__).join('../../../../resources/network/adapter').realpath
          @files = source_files(root)
          builder = Images::Configuration.reference(context.configuration.dig('images', 'network_adapter_builder'),
                                                    registry: context.configuration.dig('images', 'registry'))
          digest = Infrastructure::Definition.fingerprint(@files)
          @recipe = root.join('Containerfile').read.gsub('@BUILDER@', builder) + "\n# source-sha256: #{digest}\n"
          @image = Images::Configuration.local_image(@recipe, purpose: 'peer-adapter')
        end

        def source_files(root)
          files = root.children.select { |path| path.extname == '.go' || path.basename.to_s == 'go.mod' }
                      .to_h { |path| [path.basename.to_s, path.binread] }
          files.merge('LICENSE' => Pathname(__dir__).join('../../../../LICENSE').read)
        end

        def ensure!(runtime)
          runtime.ensure_image(image, recipe: recipe, files: files)
        end
      end
    end
  end
end
