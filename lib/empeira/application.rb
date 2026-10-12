# frozen_string_literal: true

module Empeira
  class Application
    Context = Data.define(:project, :workspace, :configuration, :platform, :locations) do
      def container_engine
        configuration.fetch('runtime').fetch('container_engine')
      end
    end

    attr_reader :context, :runner

    # Dependencies are explicit at this single composition boundary.
    # rubocop:disable Metrics/ParameterLists
    def initialize(project_path: Dir.pwd, overrides: {}, platform: Platform::Facts.new, runner: nil,
                   factories: {}, locations: nil, build_info: BuildInfo.load, progress: Progress.new,
                   recovery: false, recovery_path: nil)
      @runner = runner || Execution::Runner.new(platform: platform)
      locations ||= Platform::Locations.new(facts: platform)
      if recovery
        @context = recovery_context(project_path, recovery_path, platform, locations)
      else
        raise ConfigurationError, 'Explicit recovery project paths are only available for destroy' if recovery_path

        project = ProjectRoot.resolve(project_path, runner: @runner)
        @context = build_context(project:, locations:, platform:, overrides:)
      end
      @progress = progress
      @build_info = build_info
      @factories = { providers: Node.registry, runtimes: Runtime.registry,
                     engines: VM.registry }.merge(factories).freeze
    end

    # rubocop:enable Metrics/ParameterLists

    def infrastructure
      Infrastructure::Service.new(context: context, runner: runner, runtimes: @factories.fetch(:runtimes),
                                  build_info: @build_info, progress: @progress)
    end

    def updates
      Updates::Service.new(context: context, runner: runner, runtimes: @factories.fetch(:runtimes),
                           build_info: @build_info, progress: @progress)
    end

    def addons
      Addons::Service.new(context: context, runner: runner)
    end

    def nodes
      Node::Service.new(context: context, runner: runner, **@factories, build_info: @build_info, progress: @progress,
                        ssh_preferences: @ssh_preferences)
    end

    def run_node(hostname:, provider:)
      request = Node::RunRequest.from_config(hostname: hostname, provider: provider, config: context.configuration)
      nodes.run(request)
    end

    private

    # rubocop:disable-next Metrics/AbcSize -- Resolve the saved owner independently of live project configuration.
    def recovery_context(project_path, recovery_path, platform, locations)
      project = ProjectRoot.resolve(project_path, runner: @runner, recovery: true) unless recovery_path
      workspace = recovery_path ? Workspace.recover(recovery_path) : Workspace.new(path: project)
      configuration = Configuration::Document.new.read(Configuration::Loader::DEFAULTS)
      Configuration::Schema.new.validate_effective!(configuration)
      context = Context.new(project: project, workspace: workspace, configuration: configuration,
                            platform: platform, locations: locations)
      state = Infrastructure::Store.new(context: context, recovery: true).load
      configuration.fetch('runtime')['container_engine'] = state.fetch('runtime') if state
      @ssh_preferences = {}.freeze
      Context.new(project: project, workspace: workspace, configuration: Immutable.deep_freeze(configuration),
                  platform: platform, locations: locations)
    end

    def build_context(project:, locations:, platform:, overrides:)
      loader = Configuration::Loader.new(project_path: project, locations: locations)
      configuration = loader.load(overrides: overrides)
      @ssh_preferences = loader.ssh_preferences
      workspace = Workspace.new(path: project)
      Context.new(project: project, workspace: workspace, configuration: Immutable.deep_freeze(configuration),
                  platform: platform, locations: locations)
    end
  end
end
