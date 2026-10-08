# frozen_string_literal: true

module Empeira
  module Modules
    class Installer
      def initialize(runtime:, image:, git:, progress: Progress.new)
        @git = git
        @runtime = runtime
        @image = image
        @progress = progress
        @events = Events.new(progress: progress)
      end

      # rubocop:disable-next Metrics/AbcSize -- Plan, host acquisition, sync and cleanup share one disposable helper.
      def synchronize(request, destination, state:)
        request.data.fetch('overrides').each { |name| @progress.heartbeat("#{name} (local override)") }
        Dir.mktmpdir('empeira-puppetfile-') do |input|
          write_input(request, input, state)
          @sources = state.sources
          @runtime.with_update_helper(image: @image, input: input, output: destination,
                                      sources: state.sources, cache: state.cache) do |resource|
            @resource = resource
            execute('plan')
            acquire_git
            execute('sync')
            @events.finish!
            @names | request.data.fetch('overrides')
          end
        end
      end

      private

      def execute(mode)
        command = ['ruby', '/opt/empeira-modules/worker.rb', '/work', mode]
        result = @runtime.service_exec(@resource, command, timeout: 600, on_stdout: @events.method(:observe))
        return if result.success?

        diagnostic = Execution::Diagnostics.clean("#{result.stderr}\n#{result.stdout}")
        if diagnostic.empty?
          diagnostic = 'Check Puppetfile syntax, module names, refs/versions ' \
                       'and your normal host/container network access.'
        end
        raise Error, "Puppetfile synchronization failed#{' (timed out)' if result.timed_out}:\n" \
                     "#{"Module: #{@events.name}\n" if @events.name}#{diagnostic}", cause: nil
      end

      def acquire_git
        Dir.mktmpdir('empeira-git-sources-') do |directory|
          plan = File.join(directory, 'git-sources.json')
          @runtime.copy_from(@resource, '/work/git-sources.json', plan)
          plan_data = JSON.parse(File.read(plan))
          @names = plan_data.fetch('names')
          acquired = @git.prepare(plan_data.fetch('git'), directory: @sources) { |name| @events.start(name) }
          path = File.join(directory, 'acquired.json')
          File.write(path, JSON.generate(acquired))
          @runtime.copy_to(@resource, path, '/work/acquired.json') unless acquired.empty?
        end
      rescue JSON::ParserError, SystemCallError
        raise Error, 'Cannot transfer the Puppetfile Git source plan or cache locations', cause: nil
      end

      def write_input(request, directory, state)
        data = request.data.merge('sources' => state.sources.to_s, 'cache' => state.cache.to_s)
        { 'Puppetfile' => request.puppetfile, 'request.json' => JSON.generate(data) }.each do |name, content|
          File.write(File.join(directory, name), content, mode: 'wx', perm: 0o600)
        end
      end
    end
  end
end
