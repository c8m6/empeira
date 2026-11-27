# frozen_string_literal: true

require 'rbconfig'

module Empeira
  module Updates
    class CommandFailed < Empeira::Error
      attr_reader :exit_status

      def initialize(message, exit_status:)
        @exit_status = exit_status || 1
        super(message)
      end
    end

    class Service
      TARGETS = %w[images modules all].freeze
      INSTALLED_VERSION = <<~RUBY
        Gem.use_paths(ARGV.fetch(0), [ARGV.fetch(0)])
        spec = Gem::Specification.find_all_by_name('empeira').reject { |item| item.version.prerelease? }.max_by(&:version)
        abort 'No stable Empeira gem is installed.' unless spec
        puts spec.version
      RUBY

      def initialize(context: nil, runner: nil, runtimes: nil, build_info: BuildInfo.load, progress: Progress.new)
        @context = context
        @runner = runner || Execution::Runner.new
        @runtimes = runtimes
        @build_info = build_info
        @progress = progress
      end

      def self_update
        executable = File.join(RbConfig::CONFIG.fetch('bindir'), 'gem')
        spec = installed_gem(executable)
        unless spec
          raise UnavailableFeature, 'Self-update requires a regular RubyGems installation. ' \
                                    'Git checkouts, Bundler and other installation environments are unsupported; ' \
                                    'update using your original installation method.'
        end

        environment = { 'GEM_HOME' => spec.base_dir, 'GEM_PATH' => spec.base_dir }
        ruby!([executable, 'update', 'empeira', '--norc', '--no-prerelease', '--no-document',
               '--clear-sources', '--source', Gem::DEFAULT_HOST, '--install-dir', spec.base_dir,
               '--bindir', Gem.bindir(spec.base_dir)], environment)
        [spec, installed_version(spec, environment)]
      end

      def update(target)
        raise Error, "Select an update target: #{TARGETS.join(', ')}" unless TARGETS.include?(target)
        return update_artifacts(target) unless target == 'all'

        spec, version = self_update
        %w[images modules].each do |artifact|
          result = @runner.stream(RbConfig.ruby,
                                  arguments: ['-rrubygems', '-e',
                                              'load Gem.activate_bin_path("empeira", "empeira", ARGV.shift)',
                                              version.to_s, 'update', artifact],
                                  environment: { 'GEM_HOME' => spec.base_dir, 'GEM_PATH' => spec.base_dir })
          next if result.success?

          exit_status = result.exit_status
          raise CommandFailed.new("empeira update #{artifact} failed (exit=#{exit_status}).", exit_status: exit_status)
        end
      end

      private

      def installed_gem(executable)
        return if defined?(Bundler)

        spec = Gem.loaded_specs['empeira']
        return unless spec && File.file?(executable) && File.file?(spec.spec_file)
        return unless File.identical?(spec.full_gem_path, File.expand_path('../../..', __dir__))

        spec
      rescue SystemCallError
        nil
      end

      def ruby!(arguments, environment)
        result = @runner.run(RbConfig.ruby, arguments: arguments, environment: environment)
        return result.stdout.strip if result.success?

        message = Execution::Diagnostics.command(result, operation: 'Empeira self-update', tool: 'RubyGems')
        raise CommandFailed.new(message, exit_status: result.exit_status)
      end

      def installed_version(spec, environment)
        version = ruby!(['-rrubygems', '-e', INSTALLED_VERSION, spec.base_dir], environment)
        unless version.match?(/\A\d+(?:\.\d+)*\z/) && Gem::Version.new(version) >= spec.version
          raise Error, 'RubyGems completed, but the installed Empeira version could not be verified.'
        end

        Gem::Version.new(version)
      end

      def update_artifacts(target)
        @build_info.require_compatible!(@context.configuration.dig('requirements', 'empeira'))
        Infrastructure::Store.new(context: @context).resource_lock("update/#{target}").synchronize do
          runtime = @runtimes.build(@context.container_engine, context: @context, runner: @runner)
          runtime.check_available!
          if target == 'modules'
            Modules.new(context: @context, runtime: runtime, runner: @runner, progress: @progress).synchronize
          else
            Images.new(context: @context, runtime: runtime, progress: @progress).refresh
          end
        end
      end
    end
  end
end
