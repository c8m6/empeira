# frozen_string_literal: true

module Empeira
  module Runtime
    module ServiceImages
      def ensure_image(image, recipe: nil, files: {})
        result = runner.run(name, arguments: ['image', 'inspect', image], timeout: 30)
        return verify_recipe!(result, recipe) if result.success?
        return build_image(image, recipe, files) if recipe

        update_command(['pull', image], operation: "image pull #{image}", registry: image)
      end

      def refresh_image(image, recipe: nil, files: {}, &progress)
        unless @image_metadata
          return with_image_updates { refresh_image(image, recipe: recipe, files: files, &progress) }
        end

        observed = local_image(image)
        return refresh_recipe(image, recipe, files, observed, &progress) if recipe

        digest = remote_digest(image)
        return :unchanged if same_remote_image?(image, observed, digest)

        progress&.call(:updating)
        update_command(['pull', image], operation: "image pull #{image}", registry: image)
        :updated
      end

      def image_id(image)
        result = service_command(['image', 'inspect', image], operation: 'image identity')
        data = parse_json(result.stdout)
        unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash) && data.first['Id'].is_a?(String)
          malformed!
        end
        data.first.fetch('Id')
      end

      def image_architecture(image)
        result = service_command(['image', 'inspect', image], operation: 'node image architecture')
        data = parse_json(result.stdout)
        malformed! unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
        architecture = data.first['Architecture']
        malformed! unless %w[amd64 arm64].include?(architecture)
        architecture
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Compare all three build inputs before deciding whether to rebuild.
      def refresh_recipe(image, recipe, files, observed)
        labels = observed.to_h.fetch('Config', {}).to_h.fetch('Labels', {}).to_h
        if observed && labels['io.empeira.recipe'] != Digest::SHA256.hexdigest(recipe)
          raise Providers::OwnershipError, 'Local service image does not match the recorded build recipe'
        end

        bases = base_state(recipe, refresh: true)
        if observed && labels['io.empeira.build-inputs'] == Infrastructure::Definition.fingerprint(files) &&
           bases_current?(labels, bases)
          return :unchanged
        end

        yield :updating if block_given?
        build_image(image, recipe, files, refresh: true, bases: bases)
        :updated
      end

      def verify_recipe!(result, recipe)
        return unless recipe

        return if image_labels(result.stdout)['io.empeira.recipe'] == Digest::SHA256.hexdigest(recipe)

        raise Providers::OwnershipError, 'Local service image does not match the recorded build recipe'
      end

      def image_labels(stdout)
        data = parse_json(stdout)
        malformed! unless data.is_a?(Array) && data.size == 1 && data.first.is_a?(Hash)
        config = data.first.fetch('Config', {})
        malformed! unless config.is_a?(Hash)
        labels = config.fetch('Labels', {})
        malformed! unless labels.is_a?(Hash)
        labels
      end
    end
  end
end
