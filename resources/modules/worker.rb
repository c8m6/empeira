# frozen_string_literal: true

# Runs only inside the disposable installer, never in the CLI process.
require 'bundler/setup'
require 'r10k/module_loader/puppetfile'
require 'r10k/git/cache'
require 'json'
require 'fileutils'

module EmpeiraModules
  class Invalid < StandardError; end

  # rubocop:disable-next Metrics/ClassLength -- Keep the small controlled r10k worker in one packaged file.
  class Worker
    def initialize(directory)
      @directory = File.expand_path(directory)
      @request = JSON.parse(File.read(File.join(@directory, 'request.json')))
      R10K::Logging.disable_default_stderr = true
      R10K::Git::Cache.settings[:cache_root] = @request.fetch('cache')
    end

    # rubocop:disable-next Metrics/AbcSize -- Evaluate once and describe both Forge and host-acquired Git modules.
    def plan
      sources = modules.grep(R10K::Module::Git).map { |mod| { 'name' => mod.name, 'remote' => mod.remote } }
      report('TOTAL', modules.size)
      descriptors = modules.map { |mod| descriptor(mod) }
      File.write(File.join(@directory, 'install-plan.json'),
                 JSON.generate('forge' => PuppetForge.host, 'modules' => descriptors))
      File.write(File.join(@directory, 'git-sources.json'),
                 JSON.generate('git' => sources, 'names' => modules.map(&:name).sort))
    end

    def run
      selected = prepared_modules
      selected.each { |mod| validate(mod) }
      FileUtils.mkdir_p(File.join(@directory, 'modules'))
      selected.each { |mod| install(mod) }
      @request.fetch('overrides').each { |name| FileUtils.mkdir_p(File.join(@directory, 'modules', name)) }
    end

    private

    def modules
      @modules ||= load_modules.each { |mod| validate(mod) }
    end

    def descriptor(mod)
      report('START', mod.name)
      git = mod.is_a?(R10K::Module::Git)
      version = git ? mod.desired_ref || mod.default_ref || 'HEAD' : mod.expected_version
      { 'title' => mod.title, 'name' => mod.name, 'type' => git ? 'git' : 'forge', 'version' => version }
    rescue StandardError => e
      raise Invalid, "Module #{mod.name}: cannot resolve Forge module/version; " \
                     'check module/version and your normal host/container network access',
            cause: e
    end

    def prepared_modules
      data = JSON.parse(File.read(File.join(@directory, 'install-plan.json')))
      PuppetForge.host = data.fetch('forge')
      data.fetch('modules').map { |entry| prepared_module(entry) }
    end

    def prepared_module(entry)
      options = { version: entry.fetch('version'), type: entry.fetch('type'), exclude_spec: false }
      options[:source] = acquired_git(entry.fetch('name')) if entry['type'] == 'git'
      R10K::Module.new(entry.fetch('title'), File.join(@directory, 'modules'), options)
    end

    def load_modules
      overrides = @request.fetch('overrides')
      excluded = /\A(?:#{overrides.map { |name| Regexp.escape(name) }.join('|')})\z/ unless overrides.empty?
      loader = R10K::ModuleLoader::Puppetfile.new(
        basedir: @directory, puppetfile: File.join(@directory, 'Puppetfile'),
        module_exclude_regex: excluded,
        overrides: { modules: { exclude_spec: false }, forge: { allow_puppetfile_override: true } }
      )
      loader.load!.fetch(:modules)
    rescue StandardError, ScriptError => e
      raise Invalid, 'Invalid Puppetfile: check Ruby syntax, module declarations and duplicate normalized names',
            cause: e
    end

    # rubocop:disable-next Metrics/AbcSize -- Check supported source and destination before modifying an existing module.
    def validate(mod)
      raise Invalid, 'Invalid Puppetfile: module names must be lowercase Puppet identifiers' unless
        mod.name.match?(/\A[a-z][a-z0-9_]*\z/)

      unless mod.dirname == File.join(@directory, 'modules')
        raise Invalid, 'Puppetfile moduledir/install_path must use the normal environment modules directory'
      end
      if File.symlink?(mod.full_path) || File.symlink?(File.join(mod.full_path, '.git'))
        raise Invalid, "Module #{mod.name}: refusing a symlinked module directory or Git metadata"
      end

      case mod
      when R10K::Module::Git then validate_git(mod)
      when R10K::Module::Forge then nil
      else raise Invalid, "Module #{mod.name}: only Git and Forge entries are supported"
      end
    end

    def validate_git(mod)
      return unless mod.desired_ref == :control_branch

      raise Invalid, "Module #{mod.name}: replace :control_branch with an explicit ref"
    end

    def acquired_git(name)
      raise Invalid, 'Invalid Puppetfile: module name in installer plan' unless name.match?(/\A[a-z][a-z0-9_]*\z/)

      acquired = JSON.parse(File.read(File.join(@directory, 'acquired.json')))
      mirror = acquired.fetch(name)
      unless File.dirname(mirror) == @request.fetch('sources') &&
             File.basename(mirror).match?(/\A[0-9a-f]{64}\.git\z/) && File.directory?(mirror)
        raise Invalid, "Module #{name}: host Git source is missing"
      end

      mirror
    end

    def install(mod)
      report('START', mod.name)
      mod.sync
      report('DONE', mod.name)
    rescue StandardError => e
      source = mod.is_a?(R10K::Module::Git) ? 'Git repository/ref' : 'Forge module/version'
      raise Invalid, "Module #{mod.name}: cannot synchronize #{source}; " \
                     'check availability, ref/version and your normal host/container network access',
            cause: e
    end

    def report(kind, value)
      $stdout.puts "EMPEIRA_MODULE_#{kind}:#{value}"
      $stdout.flush
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    worker = EmpeiraModules::Worker.new(ARGV.fetch(0))
    ARGV[1] == 'plan' ? worker.plan : worker.run
  rescue EmpeiraModules::Invalid => e
    # rubocop:disable-next Style/StderrPuts -- r10k sets $VERBOSE=nil; failure diagnostics must remain visible.
    $stderr.puts e.message
    # Buffered by the central runner; only filtered diagnostics reach the user's terminal.
    cause = e.cause
    3.times do
      break unless cause

      $stderr.puts cause.message # rubocop:disable Style/StderrPuts
      cause = cause.cause
    end
    exit 1
  rescue StandardError, ScriptError
    # rubocop:disable-next Style/StderrPuts -- r10k sets $VERBOSE=nil; failure diagnostics must remain visible.
    $stderr.puts 'Puppetfile synchronization failed: installer input/output is unavailable or inconsistent'
    exit 1
  end
end
