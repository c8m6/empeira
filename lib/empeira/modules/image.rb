# frozen_string_literal: true

module Empeira
  module Modules
    class Image
      def initialize(config, registry: nil)
        @config = config
        @registry = registry
      end

      def files
        %w[Gemfile Gemfile.lock worker.rb].to_h do |name|
          [name, File.read(File.join(Images::Configuration::ROOT, 'modules', name))]
        end
      end

      def recipe
        source = Images::Configuration.recipe(@config, registry: @registry)
        "#{source}\n# Managed build inputs: #{Infrastructure::Definition.fingerprint(files)}\n"
      end

      def reference
        Images::Configuration.local_image(recipe, purpose: 'r10k')
      end
    end
  end
end
