# frozen_string_literal: true

module Empeira
  module Runtime
    module RecipeBuild
      private

      def base_state(recipe, refresh:)
        Images::Recipe.bases(recipe).sort.to_h.transform_values do |reference|
          digest = refresh ? remote_digest(reference) : available_base_digest(reference)
          { 'reference' => reference, 'digest' => digest }
        end
      end

      def available_base_digest(reference)
        ensure_image(reference)
        data = local_image(reference)
        unless data && data['Architecture'] == architecture && data['Os'] == 'linux'
          raise Providers::ExecutionError, "Build base has an incompatible platform: #{reference}"
        end

        digest = local_digests(data).first
        raise Providers::ExecutionError, "Build base has no registry digest: #{reference}" unless digest

        digest
      end

      def bases_current?(labels, expected)
        text = labels['io.empeira.base-inputs']
        return false unless text

        previous = recorded_bases(text, labels['io.empeira.base-fingerprint'])
        return false unless previous.keys.sort == expected.keys.sort

        normalized = previous.to_h do |key, base|
          value = normalized_base(base, expected.fetch(key))
          return false unless value

          [key, value]
        end
        Infrastructure::Definition.fingerprint(normalized) == Infrastructure::Definition.fingerprint(expected)
      end

      def recorded_bases(text, fingerprint)
        previous = JSON.parse(text)
        unless previous.is_a?(Hash) && Infrastructure::Definition.fingerprint(previous) == fingerprint
          raise Providers::OwnershipError, 'Invalid local build base metadata'
        end

        previous
      rescue JSON::ParserError
        raise Providers::OwnershipError, 'Unreadable local build base metadata', cause: nil
      end

      def normalized_base(base, current)
        return unless base.is_a?(Hash) && base['reference'] == current['reference'] && valid_digest?(base['digest'])

        digest = base['digest']
        digest = remote_digest(Images::Reference.pinned(base['reference'], digest)) if digest != current['digest']
        base.merge('digest' => digest)
      end

      def build_image(image, recipe, files, refresh: false, bases: nil)
        bases ||= base_state(recipe, refresh: refresh)
        Dir.mktmpdir('empeira-image-') do |directory|
          write_build_context(directory, recipe, files)
          labels = build_labels(recipe, files, bases)
          arguments = ['build', *(refresh ? ['--pull'] : []), '--tag', image,
                       *labels.flat_map { |key, value| ['--label', "#{key}=#{value}"] },
                       *base_arguments(bases),
                       '--file', File.join(directory, 'Containerfile'), directory]
          update_command(arguments, operation: 'managed image build', timeout: 600)
        end
      end

      def build_labels(recipe, files, bases)
        { 'io.empeira.recipe' => Digest::SHA256.hexdigest(recipe),
          'io.empeira.build-inputs' => Infrastructure::Definition.fingerprint(files),
          'io.empeira.base-inputs' => JSON.generate(bases),
          'io.empeira.base-fingerprint' => Infrastructure::Definition.fingerprint(bases) }
      end

      def base_arguments(bases)
        bases.flat_map do |key, base|
          reference = Images::Reference.pinned(base.fetch('reference'), base.fetch('digest'))
          ['--build-arg', "#{key}=#{reference}"]
        end
      end

      def write_build_context(directory, recipe, files)
        files.each do |name, content|
          unless name.match?(/\A[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\z/) && content.is_a?(String)
            raise ConfigurationError, 'Image context must contain named reviewed resource files'
          end

          File.write(File.join(directory, name), content)
        end
        File.write(File.join(directory, 'Containerfile'), recipe)
      end
    end
  end
end
