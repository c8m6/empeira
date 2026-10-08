# frozen_string_literal: true

require 'empeira/completion/catalog'
require 'empeira/completion/bash'
require 'empeira/cli/main'

RSpec.describe Empeira::Completion::Catalog do
  around { |example| Dir.chdir(@directory) { example.run } }

  subject(:catalog) { described_class.new }

  it 'completes commands, node subcommands and node-only provider flags' do
    expect(catalog.candidates([''], 0)).to include('node', 'config', '--version')
    expect(catalog.candidates(%w[node r], 1)).to eq(['run'])
    expect(catalog.candidates(%w[node run host1 --pr], 3)).to eq(['--provider'])
    expect(catalog.candidates(%w[config show --pr], 2)).to be_empty
  end

  it 'completes infrastructure and update commands without executing runtimes' do
    expect(catalog.candidates([''], 0)).to include('up', 'down', 'self-update')
    expect(catalog.candidates(['update', ''], 1)).to include(*Empeira::Updates::Service::TARGETS)
    expect(Empeira::Execution::Runner).not_to receive(:new)
    expect { Empeira::CLI::Main.start(%w[completion bash]) }.to output.to_stdout
  end

  it 'completes user SSH options and proxy diagnostics' do
    expect(catalog.candidates(%w[node ssh host1 --u], 3)).to eq(['--user'])
    expect(catalog.candidates(%w[node ssh host1 --i], 3)).to eq(['--identity'])
    expect(catalog.candidates(%w[proxy s], 1)).to eq(['show'])
  end

  it 'completes provider and runtime values after options' do
    expect(catalog.candidates(['node', 'run', 'host1', '--provider', ''], 4)).to eq(%w[container vm])
    expect(catalog.candidates(['config', 'show', '--container-engine', ''], 3)).to eq(%w[podman docker])
  end

  it 'offers run options after the hostname without requiring a provider selection' do
    expect(catalog.candidates(['node', 'run', 'host1', ''], 3)).to include('--provider', '--os', '--memory')
    expect(catalog.candidates(['node', 'run', 'host1', '--os', ''], 4)).to include('ubuntu')
  end

  it 'handles options before commands and filters partial words' do
    expect(catalog.candidates(['--container-engine', 'docker', 'node', ''], 3)).to include('run', 'stop')
    expect(catalog.candidates(%w[node run h --provider c], 4)).to eq(['container'])
    expect(catalog.candidates(['node', 'run', 'h', '--os', ''], 4)).to include('ubuntu', 'rocky')
  end

  it 'generates a working Bash definition and obtains candidates from the executable' do
    script = File.join(@directory, 'completion.bash')
    File.write(script, Empeira::Completion::Bash.generate)
    binary = File.expand_path('../bin/empeira', __dir__)
    code = 'source "$1"; COMP_WORDS=("$2" node run host1 --provider ""); COMP_CWORD=5; '
    code += '_empeira_complete; printf "%s\n" "${COMPREPLY[@]}"'
    result = Empeira::Execution::Runner.new.run('bash', arguments: ['-c', code, 'empeira-spec', script, binary],
                                                        timeout: 15)
    expect(result).to be_success
    expect(result.stdout.lines.map(&:strip)).to eq(%w[container vm])
  end
  {
    ['--provider=con'] => ['--provider=container'],
    ['--provider=vm'] => ['--provider=vm'],
    ['--provider=', 'con'] => ['container'],
    ['--provider', '=', 'con'] => ['container'],
    ['--provider', '=con'] => ['=container'],
    ['--provider', '=', ''] => %w[container vm],
    ['--container-engine=do'] => ['--container-engine=docker']
  }.each do |suffix, expected|
    it "completes the assignment form #{suffix.inspect}" do
      words = %w[node run host1] + suffix
      expect(catalog.candidates(words, words.length - 1)).to eq(expected)
    end
  end

  it 'handles split assignment options before command names' do
    words = ['--container-engine', '=', 'docker', 'node', 'r']
    expect(catalog.candidates(words, 4)).to eq(['run'])
  end

  it 'keeps command vocabulary aligned with the public Thor commands' do
    { [] => Empeira::CLI::Main, ['node'] => Empeira::CLI::Node,
      ['update'] => Empeira::CLI::Update, ['config'] => Empeira::CLI::Config,
      ['proxy'] => Empeira::CLI::Proxy }.each do |path, cli|
      commands = cli.commands.values.reject(&:hidden?).map { |command| command.usage.split.first }
      expect(described_class::COMMANDS.fetch(path).sort).to eq((commands + ['help']).uniq.sort)
    end
  end

  it 'uses the same provider values and node options as the CLI' do
    run = Empeira::CLI::Node.commands.fetch('run_node')
    expect(catalog.candidates(['node', 'run', 'host1', '--provider', ''], 4)).to eq(run.options.fetch(:provider).enum)
    expect(catalog.candidates(['config', 'show', '--container-engine', ''], 3))
      .to eq(Empeira::CLI::Base.class_options.fetch(:container_engine).enum)
    options = run.options.keys.map { |name| "--#{name.to_s.tr('_', '-')}" }
    expect(described_class::NODE_OPTIONS.sort).to eq(options.sort)
  end

  it 'loads project OS versions for split assignments and inventory names without runtime execution' do
    image = { 'reference' => 'example.invalid/node:1', 'architectures' => ['amd64'] }
    File.write(File.join(@directory, '.empeira.yaml'),
               YAML.dump('images' => { 'nodes' => { 'example' => { '1' => image } } }))
    words = ['node', 'run', 'h', '--os', '=', 'example', '--version', '']
    expect(catalog.candidates(words, words.size - 1)).to eq(['1'])
    allow_any_instance_of(Empeira::Node::Service).to receive(:names).and_return(%w[alpha beta])
    expect_any_instance_of(Empeira::Runtime::Container).not_to receive(:check_available!)
    %w[start stop destroy shell ssh puppet logs].each do |operation|
      words = ['node', operation, 'a']
      expect(catalog.candidates(words, words.size - 1)).to eq(['alpha'])
    end
    expect(catalog.candidates(['destroy', '--'], 1)).not_to include('--confirm')
  end

  it 'protects nested shared configuration and completion definitions' do
    expect { described_class::COMMANDS.fetch([]) << 'unwanted' }.to raise_error(FrozenError)
    expect { Empeira::Configuration::Loader::CLI_PATHS.first << 'unwanted' }.to raise_error(FrozenError)
  end
  {
    ['--provider=con'] => '--provider=container',
    ['--provider', '=', 'con'] => 'container',
    ['--provider=', 'v'] => 'vm'
  }.each do |suffix, expected|
    it "passes #{suffix.inspect} through the generated Bash adapter" do
      script = File.join(@directory, 'completion.bash')
      File.write(script, Empeira::Completion::Bash.generate)
      binary = File.expand_path('../bin/empeira', __dir__)
      code = 'source "$1"; executable="$2"; shift 2; COMP_WORDS=("$executable" node run host1 "$@"); '
      code += 'COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); _empeira_complete; printf "%s\n" "${COMPREPLY[@]}"'
      result = Empeira::Execution::Runner.new.run('bash',
                                                  arguments: ['-c', code, 'empeira-spec', script, binary, *suffix],
                                                  timeout: 15)
      expect(result).to be_success
      expect(result.stderr).to be_empty
      expect(result.stdout.strip).to eq(expected)
    end
  end
end
