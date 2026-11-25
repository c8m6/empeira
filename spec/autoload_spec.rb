# frozen_string_literal: true

RSpec.describe 'Independent lazy entry points', :files_only do
  def isolated(source, *arguments)
    Empeira::Execution::Runner.new.run(RbConfig.ruby,
                                       arguments: ['-I', File.expand_path('../lib', __dir__), '-rempeira',
                                                   '-e', source, *arguments], timeout: 15)
  end

  it 'loads CLI subcommands and redirect validation without an earlier main or schema require' do
    %w[config node proxy completion].each do |command|
      result = isolated('require "empeira/cli/" + ARGV.fetch(0); ' \
                        'Empeira::CLI.const_get(ARGV.fetch(0).capitalize).start(["help"])', command)
      expect(result).to be_success, result.stderr
    end
    result = isolated('Empeira::Configuration::NetworkRedirects')
    expect(result).to be_success, result.stderr
  end

  it 'initializes each runtime, node provider and VM engine in a fresh process' do
    initialize_project(@directory)
    source = <<~RUBY
      namespace, constant, name, directory = ARGV
      catalog = Empeira.const_get(namespace)
      catalog.const_get(constant)
      locations = Empeira::Platform::Locations.new(home: directory, environment: {})
      app = Empeira::Application.new(project_path: directory, locations: locations)
      options = { context: app.context, runner: app.runner }
      if namespace == 'Node'
        options.merge!(runtimes: Empeira::Runtime.registry, engines: Empeira::VM.registry,
                       build_info: Empeira::BuildInfo.load, progress: Empeira::Progress.new)
      end
      abort 'Unexpected provider' unless catalog.registry.build(name, **options).name == name
    RUBY
    [%w[Runtime Podman podman], %w[Runtime Docker docker], %w[Node Container container],
     %w[Node VM vm], %w[VM Qemu qemu]].each do |selection|
      result = isolated(source, *selection, @directory)
      expect(result).to be_success, result.stderr
    end
  end

  it 'preserves native guest errors before channel libraries have loaded' do
    result = isolated(<<~RUBY)
      guest = Empeira::VM::Guest.new(context: nil, runner: nil, qemu: nil)
      begin
        guest.run({}, ['true'])
        abort 'Invalid management record was accepted'
      rescue Empeira::Error => e
        abort e.message unless e.message.include?('Incompatible VM management layout')
      end
    RUBY
    expect(result).to be_success, result.stderr
  end

  it 'runs interactive-tool reconciliation without configuration loading standard libraries first' do
    result = isolated(<<~RUBY)
      result = Empeira::Execution::Result.new(stdout: '{"changed":false}', stderr: '', exit_status: 0, timed_out: false)
      tools = Empeira::Node::InteractiveTools.new(record: {}, persist: -> {}, execute: ->(_) { result })
      abort 'Unexpected change' if tools.reconcile
      abort 'Missing fingerprint' unless Empeira::Node::ExternalFact.fingerprint('container').size == 64
    RUBY
    expect(result).to be_success, result.stderr
  end
end
