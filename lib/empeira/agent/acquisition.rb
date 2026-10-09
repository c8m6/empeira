# frozen_string_literal: true

module Empeira
  module Agent
    # One source-resolution and acquisition path for both providers and both install methods.
    class Acquisition
      def initialize(context:, runtime:, progress: Progress.new)
        @context = context
        @runtime = runtime
        @progress = progress
      end

      def with_package(requirements)
        prepare(requirements)
        request = identity
        acquire = ->(directory) { fetch(directory, request) }
        cache.with_artifact(request, enabled: @context.configuration.dig('agent', 'cache', 'enabled'),
                                     acquire: acquire, pin: package_pin) do |artifact|
          @progress.heartbeat('Installing the resolved local agent package...')
          yield artifact
        end
      end

      def preflight!(requirements)
        return unless requirements.required?

        @runtime.check_available!
        return if @runtime.architecture == requirements.target.architecture

        raise Error, 'Agent package helper architecture differs from the target; emulation is not enabled'
      end

      private

      def cache
        Cache.new(root: @context.locations.cache.join('agents'), temporary: @context.locations.temporary)
      end

      def prepare(requirements)
        @requirements = requirements
        @target = requirements.target
        @source = requirements.repository
      end

      def identity
        { 'package' => @requirements.agent.fetch('package'),
          'requested_version' => @requirements.agent.fetch('version'),
          'family' => @target.family, 'distribution' => @target.os, 'release' => @target.release,
          'architecture' => @target.architecture, 'format' => @target.format, 'suffix' => @source['suffix'],
          'source' => Cache.fingerprint(@source), 'method' => @requirements.agent.dig('install', 'method') }
      end

      def package_pin
        return @source['sha256'] unless @source['url'].end_with?('.deb', '.rpm') &&
                                        @requirements.agent.dig('install', 'method') == 'repository'

        nil
      end

      def fetch(directory, request)
        @authentication = Authentication.new(url: @source.fetch('url'), progress: @progress)
        @download = Download.new(authentication: @authentication)
        @progress.heartbeat('Resolving and acquiring the agent package...')
        image = helper_image
        @runtime.with_agent_helper(image: image.reference) do |resource|
          resolver = native_source(resource, directory)
          path, metadata, selected = acquire_package(resolver, directory, request)
          describe(path, metadata, selected, resolver, request)
        end
      end

      # rubocop:disable-next Metrics/AbcSize -- Keep native resolution, acquisition and identity verification together.
      def acquire_package(resolver, directory, request)
        direct = request.fetch('method') == 'package'
        resolver.prepare_keys if direct
        selected = direct ? { 'url' => @source.fetch('url'), 'sha256' => package_pin } : resolver.resolve
        path = Pathname(directory).join("package.#{@target.format}")
        @download.fetch(selected.fetch('url'), path, sha256: package_pin || selected['sha256'])
        metadata = resolver.inspect_package(path)
        if selected['version'] && metadata['version'] != selected['version']
          raise Error, 'Agent package version differs from its native repository metadata'
        end

        [path, metadata, selected]
      end

      def describe(path, metadata, selected, resolver, request)
        details = { 'schema' => 1, 'request' => request, 'url' => selected.fetch('url'),
                    'sha256' => Digest::SHA256.file(path).hexdigest, 'size' => path.size,
                    'public_keys' => resolver.public_keys,
                    'verify_signatures' => @source.fetch('verify_signatures', true) }
        Artifact.new(path: path, metadata: metadata.merge(details))
      end

      def native_source(resource, directory)
        klass = @target.family == 'debian' ? Node::AgentRepository : Node::DnfAgentRepository
        execute = ->(arguments) { @runtime.service_exec(resource, arguments, timeout: 300) }
        copy = lambda do |source, destination, mode|
          @runtime.copy_to(resource, source, destination)
          raise Error, 'Cannot set agent helper file permissions' unless execute.call(['chmod', mode,
                                                                                       destination]).success?
        end
        klass.new(source: @source, package: @requirements.agent.fetch('package'),
                  version: @requirements.agent.fetch('version'), target: @target, execute: execute, copy: copy,
                  download: @download, authentication: @authentication, directory: directory)
      end

      def helper_image
        preflight!(@requirements)
        request = Struct.new(:os, :version).new(@target.os, @target.release)
        image = Node::Image.new(config: @context.configuration, request: request, architecture: @target.architecture)
        @runtime.ensure_image(image.reference, recipe: image.recipe, files: image.build_files)
        raise Error, 'Agent helper image architecture differs from the target' unless
          @runtime.image_architecture(image.reference) == @target.architecture

        image
      end
    end
  end
end
