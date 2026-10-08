# frozen_string_literal: true

module Empeira
  module Updates
    # Caller owns the existing workspace lock. r10k updates the live module directory in place.
    class Modules
      def initialize(context:, runtime:, runner:, progress: Progress.new)
        @context = context
        @runtime = runtime
        @runner = runner
        @progress = progress
        @storage = Empeira::Modules::Storage.new(context: context)
        @state = Empeira::Modules::State.new(context: context)
      end

      def synchronize
        request = Empeira::Modules::Request.new(context: @context)
        request.warnings.each { |message| @progress.warning(message) }
        return unless request.present?

        Empeira::Modules::GitSafety.new(project: @context.project.path, runner: @runner, progress: @progress)
                                   .verify(@storage.root, recommend: true)
        install(request)
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Preserve the ordered direct-sync and success-marker boundary.
      def install(request)
        @progress.stage(0, 'Reading Puppetfile...')
        image = Empeira::Modules::Image.new(@context.configuration.dig('images', 'r10k'),
                                            registry: @context.configuration.dig('images', 'registry'))
        @runtime.ensure_image(image.reference, recipe: image.recipe, files: image.files)
        @storage.prepare
        @state.prepare
        @state.invalidate
        git = Empeira::Modules::HostGit.new(runner: @runner, project: @context.project.path, progress: @progress)
        installer = Empeira::Modules::Installer.new(runtime: @runtime, image: image.reference,
                                                    git: git, progress: @progress)
        names = installer.synchronize(request, @storage.root, state: @state)
        @state.record(@storage.root, names)
      end
    end
  end
end
