# frozen_string_literal: true

require 'empeira/cli/main'

RSpec.describe Empeira::ProjectRoot do
  it 'resolves relative paths and traversal consistently' do
    path = Pathname(@directory)
    relative = path.relative_path_from(Pathname(Dir.pwd))
    expect(described_class.resolve(relative).path).to eq(path.realpath)
    child = path.join('child')
    child.mkdir
    expect(described_class.resolve(child.join('..')).path).to eq(path.realpath)
    expect(Empeira::Workspace.new(path: relative).id).to eq(Empeira::Workspace.new(path: path).id)
  end

  it 'follows symlinks before resolving parent traversal for both configuration and identity' do
    local = Pathname(@directory).join('local')
    target = Pathname(@directory).join('target')
    initialize_project(local)
    initialize_project(target)
    target.join('child').mkdir
    File.symlink(target.join('child'), local.join('link'))
    local.join('.empeira.yaml').write('node_defaults: {memory: 4096}')
    target.join('.empeira.yaml').write('node_defaults: {memory: 2048}')
    application = Empeira::Application.new(project_path: File.join(local, 'link', '..'))
    expect(application.context.configuration['node_defaults']['memory']).to eq(2048)
    expect(application.context.project.path).to eq(target.realpath)
    expect(application.context.workspace.id).to eq(Empeira::Workspace.new(path: target).id)
    expect(application.context.workspace.id).not_to eq(Empeira::Workspace.new(path: local).id)
  end
end

RSpec.describe 'Explicit project boundary' do
  it 'requires Git rather than inferring a project from Puppet files' do
    FileUtils.rm_rf(File.join(@directory, '.git'))
    File.write(File.join(@directory, 'Puppetfile'), '')
    expect { Empeira::ProjectRoot.resolve(@directory) }
      .to raise_error(Empeira::ConfigurationError, /Empeira Git project is required/)
  end

  it 'reports the canonical root, missing marker and shell-safe opt-in command' do
    root = File.join(@directory, 'project with spaces')
    initialize_project(root)
    File.unlink(File.join(root, '.empeira.yaml'))
    expect { Empeira::ProjectRoot.resolve(root) }.to raise_error(Empeira::ConfigurationError) do |error|
      marker = File.join(File.realpath(root), '.empeira.yaml')
      expect(error.message).to include(File.realpath(root), marker, "touch #{Shellwords.escape(marker)}")
    end
  end

  it 'uses the same Git root and configuration from any subdirectory, including symlinked paths' do
    root = Pathname(@directory)
    root.join('.empeira.yaml').write('node_defaults: {memory: 4096}')
    child = root.join('path with spaces/child')
    FileUtils.mkdir_p(child)
    link = root.join('alias')
    File.symlink(child, link)
    app = Empeira::Application.new(project_path: link)
    expect(app.context.project.path).to eq(root.realpath)
    expect(app.context.configuration.dig('node_defaults', 'memory')).to eq(4096)
    expect(app.context.workspace.id).to eq(Empeira::Workspace.new(path: root).id)
  end

  it 'canonicalizes a Git-reported symlink root as on macOS /var to /private/var' do
    alias_path = File.join(@directory, 'canonical-alias')
    File.symlink(@directory, alias_path)
    runner = instance_double(Empeira::Execution::Runner)
    result = Empeira::Execution::Result.new(stdout: "#{alias_path}\n", stderr: '', exit_status: 0, timed_out: false)
    expect(runner).to receive(:run).with('git', arguments: %w[rev-parse --show-toplevel],
                                                directory: Pathname(@directory).realpath, timeout: 10)
                                   .and_return(result)
    expect(Empeira::ProjectRoot.resolve(@directory, runner: runner).path).to eq(Pathname(@directory).realpath)
  end

  it 'permits independent commands outside Git but rejects all project-bound entry points' do
    FileUtils.rm_rf(File.join(@directory, '.git'))
    runner = Empeira::Execution::Runner.new
    binary = File.expand_path('../bin/empeira', __dir__)
    [%w[--version], %w[help], %w[completion bash], %w[self-update]].each do |args|
      result = runner.run(RbConfig.ruby, arguments: [binary, *args], directory: @directory)
      expect(result.stderr).not_to include('Git project')
      expect(result).to be_success unless args == ['self-update']
    end
    [%w[up], %w[status], %w[down], %w[destroy], %w[browser], %w[node list],
     %w[proxy show host], %w[config show], %w[config validate], %w[update images]].each do |args|
      result = runner.run(RbConfig.ruby, arguments: [binary, *args], directory: @directory)
      expect(result).not_to be_success
      expect(result.stderr).to include('Empeira Git project is required')
    end
  end

  it 'removes the public project override and removed toolbox commands' do
    expect(Empeira::CLI::Main.class_options).not_to have_key(:project)
    expect(Empeira::CLI::Main.commands).not_to have_key('convert')
    expect(Empeira::Updates::Service::TARGETS).not_to include('hooks')
  end
end
