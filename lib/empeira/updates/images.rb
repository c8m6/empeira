# frozen_string_literal: true

module Empeira
  module Updates
    # Container artifacts only; existing containers and immutable VM bases stay attached to their revisions.
    class Images
      def initialize(context:, runtime:, progress: Progress.new)
        @context = context
        @config = context.configuration
        @runtime = runtime
        @progress = progress
      end

      def refresh
        @state = Infrastructure::Store.new(context: @context).load
        if @state && @state.fetch('runtime') != @context.container_engine
          raise Error, 'Workspace belongs to another runtime; select its owning runtime before updating images'
        end

        artifacts = catalog
        @runtime.with_image_updates do
          artifacts.each_with_index do |entry, index|
            update(entry, index, artifacts.size)
          end
        end
      end

      private

      def update(entry, index, total)
        label = entry.fetch(:label)
        @progress.count(index, total, "#{label} (#{index}/#{total})")
        result = @runtime.refresh_image(entry.fetch(:image), **entry.except(:image, :label)) do |status|
          @progress.count(index, total, "#{label} — #{status} (#{index + 1}/#{total})")
        end
        @progress.count(index + 1, total, "#{label} — #{result} (#{index + 1}/#{total})")
      rescue Error => e
        raise e.class, "#{label} (#{entry.fetch(:image)}): #{e.message}", cause: nil
      end

      def catalog
        (service_images + utility_images + node_images).uniq { |entry| entry.fetch(:image) }
      end

      def service_images
        references = [
          ['Configuration server', reference(@config.dig('images', 'server'))],
          ['CoreDNS', reference(@config.dig('images', 'dns'))],
          ['Browser', reference(@config.dig('browser', 'image'))]
        ]
        references.concat(database_images)
        references.concat(@config.dig('containers', 'additional').map do |entry|
          [entry.fetch('name'), reference(entry.fetch('image'))]
        end)
        references.map { |label, image| { image: image, label: label } }
      end

      def database_images
        return [] unless @config.dig('puppetdb', 'enabled')

        [['PuppetDB', reference(@config.dig('images', 'puppetdb'))],
         ['PostgreSQL', reference(@config.dig('images', 'postgres'))]]
      end

      def utility_images
        installer = Empeira::Modules::Image.new(@config.dig('images', 'r10k'),
                                                registry: @config.dig('images', 'registry'))
        adapter = Network::Peer::AdapterImage.new(context: @context)
        direct = ControlPlane::Plan.new(context: @context).gateway_artifact
        [utility_artifact('relay', 'Service relay', purpose: 'relay'), utility_artifact('proxy', 'Squid proxy'),
         direct.merge(label: 'Workspace gateway'),
         { label: 'r10k helper', image: installer.reference, recipe: installer.recipe, files: installer.files },
         { label: 'VM network helper', image: adapter.image, recipe: adapter.recipe, files: adapter.files }]
      end

      def utility_artifact(key, label, **)
        Empeira::Images::Configuration.artifact(
          @config.dig('images', key), registry: @config.dig('images', 'registry'), **
        ).merge(label: label)
      end

      def node_images
        architecture = @runtime.architecture
        node_variants.map do |os, version|
          request = Node::RunRequest.from_config(hostname: 'image-update', provider: 'container', config: @config)
                                    .with(os: os, version: version)
          image = Node::Image.new(config: @config, request: request, architecture: architecture)
          { label: "#{os.capitalize} #{version} node image", image: image.reference,
            recipe: image.recipe, files: image.build_files }
        end
      end

      def node_variants
        used = @state.to_h.fetch('nodes', {}).values.select { |record| record['provider'] == 'container' }
        [@config.fetch('node_defaults').values_at('os', 'version'),
         *used.map { |record| record.values_at('os', 'version') }].uniq
      end

      def reference(config)
        Empeira::Images::Configuration.reference(config, registry: @config.dig('images', 'registry'))
      end
    end
  end
end
