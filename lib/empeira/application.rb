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
                   recovery: false)
      @runner = runner || Execution::Runner.new(platform: platform)
      project = ProjectRoot.resolve(project_path, runner: @runner)
      locations ||= Platform::Locations.new(facts: platform)
      @context = build_context(project:, locations:, platform:, overrides:, recovery:)
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

    def nodes
      Node::Service.new(context: context, runner: runner, **@factories, build_info: @build_info, progress: @progress,
                        ssh_preferences: @ssh_preferences)
    end

    def run_node(hostname:, provider:)
      request = Node::RunRequest.from_config(hostname: hostname, provider: provider, config: context.configuration)
      nodes.run(request)
    end

    private

    def build_context(project:, locations:, platform:, overrides:, recovery:)
      loader = Configuration::Loader.new(project_path: project, locations: locations)
      configuration = load_configuration(loader, overrides, recovery: recovery)
      @ssh_preferences = loader.ssh_preferences
      workspace = Workspace.new(path: project)
      restore_inventory_settings!(configuration, project:, workspace:, platform:, locations:) if recovery
      Context.new(project: project, workspace: workspace, configuration: Immutable.deep_freeze(configuration),
                  platform: platform, locations: locations)
    end

    def load_configuration(loader, overrides, recovery:)
      loader.load(overrides: overrides)
    rescue ConfigurationError
      raise unless recovery

      loader.load_defaults(overrides: overrides)
    end

    def restore_inventory_settings!(configuration, project:, workspace:, platform:, locations:)
      context = Context.new(project: project, workspace: workspace, configuration: configuration,
                            platform: platform, locations: locations)
      state = Infrastructure::Store.new(context: context).load
      return unless state

      configuration.fetch('runtime')['container_engine'] = state.fetch('runtime')
    end
  end
end
