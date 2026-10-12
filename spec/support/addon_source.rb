# frozen_string_literal: true

require_relative 'module_source'

# Reuse the Puppetfile suite's local Git HTTP fixture and native host Git path.
class AddonSource < ModuleSource
  attr_reader :directory

  def prepare_git
    git('init', '--quiet', '--initial-branch=fixture', @directory.to_s)
    FileUtils.cp_r("#{File.expand_path('../fixtures/addon', __dir__)}/.", @directory)
    File.chmod(0o755, @directory.join('bin/example'))
    commit_changes
    git('-C', @directory.to_s, 'tag', 'v1')
    git('-C', @directory.to_s, 'update-server-info')
  end

  def commit_changes
    git('-C', @directory.to_s, 'add', '.')
    git('-C', @directory.to_s, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '--quiet', '--allow-empty', '-m', 'Synthetic addon fixture')
    git('-C', @directory.to_s, 'update-server-info')
    @commit = git('-C', @directory.to_s, 'rev-parse', 'HEAD').strip
  end

  def script(content)
    @directory.join('bin/example').write("#!#{RbConfig.ruby}\n#{content}\n")
    commit_changes
  end
end

module AddonFixture
  def addon_project
    File.join(@directory, 'control')
  end

  def configure_addon(ref: 'fixture', name: 'example', url: "#{source.url}/fixture.git", extra: {})
    initialize_project(addon_project) unless File.directory?(File.join(addon_project, '.git'))
    config = { 'addons' => { name => { 'git' => url, 'ref' => ref } } }
    File.write(File.join(addon_project, '.empeira.yaml'), YAML.dump(Empeira::Configuration::Merge.call(config, extra)))
  end

  def addon_application
    Empeira::Application.new(project_path: addon_project)
  end

  def addon_cli(*arguments, environment: {}, directory: addon_project)
    preload = File.expand_path('isolated_cli_locations.rb', __dir__)
    environment = { 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }.merge(environment)
    argv = ['-r', preload, File.expand_path('../../bin/empeira', __dir__), *arguments]
    Empeira::Execution::Runner.new.run(RbConfig.ruby,
                                       arguments: argv,
                                       environment: environment, directory: directory, timeout: 20)
  end
end
