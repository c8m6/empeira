# frozen_string_literal: true

module Empeira
  module Images
    module Configuration
      REPOSITORY = %r{\A[a-z0-9]+(?:[._:/-][a-z0-9]+)*\z}
      TAG = /\A\w[\w.-]{0,127}\z/
      DIGEST = /\Asha256:[a-f0-9]{64}\z/
      ROOT = File.expand_path('../../../resources', __dir__)

      def self.reference(data, registry: nil)
        return data.fetch('reference') if data['reference']

        repository = Reference.repository(data.fetch('repository'), registry: registry)
        return "#{repository}@#{data['digest']}" if data['digest']

        tag = data.fetch('tag')
        "#{repository}:#{tag}"
      end

      def self.recipe(data, registry: nil)
        relative = data.fetch('build')
        path = Pathname.new(ROOT).join(relative).realpath
        unless path.to_s.start_with?("#{ROOT}/")
          raise ConfigurationError,
                'images build resource must be packaged with Empeira'
        end

        Recipe.render(File.read(path), registry: registry)
      rescue SystemCallError
        raise ConfigurationError, 'images build resource is unavailable', cause: nil
      end

      def self.artifact(data, purpose: 'squid', registry: nil)
        recipe = self.recipe(data, registry: registry) if data['build'] && !data['reference']
        { image: recipe ? local_image(recipe, purpose: purpose) : reference(data, registry: registry), recipe: recipe }
      end

      def self.local_image(recipe, purpose: 'squid')
        "localhost/empeira-#{purpose}:#{Digest::SHA256.hexdigest(recipe)}"
      end
    end
  end
end
