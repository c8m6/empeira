# frozen_string_literal: true

require_relative 'support/module_source'

RSpec.describe Empeira::Modules::HostGit do
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:git) { described_class.new(runner: runner, project: Pathname(@directory)) }
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }

  before do
    allow($stdin).to receive(:tty?).and_return(false)
  end

  it 'invokes host Git without replacing SSH identity, agent, environment or configuration' do
    expect(runner).to receive(:run).with('git',
                                         arguments: ['clone', '--mirror', '--template=', '--',
                                                     'git@private-alias:team/profile.git',
                                                     a_string_matching(%r{/[a-f0-9]{64}\.git$})],
                                         directory: Pathname(@directory), timeout: 300).and_return(success)
    git.prepare([{ 'name' => 'profile', 'remote' => 'git@private-alias:team/profile.git' }], directory: @directory)
    expect(Dir.children(@directory)).not_to include('.ssh', 'known_hosts', 'identity')
  end

  it 'never invokes Git for an excluded source' do
    expect(runner).not_to receive(:run)
    git.prepare([], directory: @directory)
  end

  it 'rejects unsafe transport plans before host execution' do
    expect(runner).not_to receive(:run)
    %w[ext::command file:///etc/secret -host:repository https://user:secret@example.org/repo].each do |remote|
      expect do
        git.prepare([{ 'name' => 'profile', 'remote' => remote }], directory: @directory)
      end.to raise_error(Empeira::Error, /invalid Git source plan/)
    end
  end

  it 'keeps failed acquisition diagnostics free of upstream credentials' do
    allow(runner).to receive(:run).and_return(
      Empeira::Execution::Result.new(stdout: '', stderr: 'private upstream secret', exit_status: 128, timed_out: false)
    )
    expect do
      git.prepare([{ 'name' => 'profile', 'remote' => 'ssh://git@private.example.org/team/profile.git' }],
                  directory: @directory)
    end.to raise_error(Empeira::Error, /Module: profile\nError: Git source acquisition failed/)
  end

  it 'shows buffered SSH failures with relevant details after sanitizing them' do
    stderr = "Permission denied (publickey).\nfatal: Could not read from remote repository.\n" \
             "fatal: https://user:secret@example.org/repo?token=hidden\nProxy-Authorization: Basic secret"
    allow(runner).to receive(:run).and_return(
      Empeira::Execution::Result.new(stdout: '', stderr: stderr, exit_status: 128, timed_out: false)
    )
    operation = lambda do
      git.prepare([{ 'name' => 'profile', 'remote' => 'git@private-alias:profile.git' }], directory: @directory)
    end
    expect(&operation).to raise_error(Empeira::Error) do |error|
      expect(error.message).to include('Module: profile', 'Permission denied (publickey)', 'Could not read')
      expect(error.full_message).not_to include('secret', 'hidden', 'Proxy-Authorization')
    end
  end
  it 'uses the inherited SSH command and agent environment during a real Git clone' do
    allow($stdin).to receive(:tty?).and_return(true)
    allow($stderr).to receive(:tty?).and_return(true)
    source = ModuleSource.new(@directory)
    wrapper = File.join(@directory, 'user-ssh')
    trace = File.join(@directory, 'ssh-trace.json')
    File.write(wrapper, <<~RUBY)
      #!#{RbConfig.ruby}
      require #{File.expand_path('../lib/empeira', __dir__).inspect}
      exit 0 if ARGV.include?('-G')
      File.write(ENV.fetch('EMPEIRA_SSH_TRACE'), JSON.generate('arguments' => ARGV, 'agent' => ENV['SSH_AUTH_SOCK']))
      exit Empeira::Execution::Runner.new.stream('git', arguments: ['upload-pack', ENV.fetch('EMPEIRA_SSH_REPO')]).exit_status
    RUBY
    File.chmod(0o700, wrapper)
    environment = { 'GIT_SSH' => wrapper, 'GIT_SSH_COMMAND' => nil, 'GIT_SSH_VARIANT' => 'ssh',
                    'SSH_AUTH_SOCK' => File.join(@directory, 'user-agent.sock'), 'EMPEIRA_SSH_TRACE' => trace,
                    'EMPEIRA_SSH_REPO' => File.join(@directory, 'source/.git') }
    previous = environment.to_h { |name, _value| [name, ENV.fetch(name, nil)] }
    ENV.update(environment)
    target = Pathname(@directory).join('acquired')
    target.mkpath
    expect do
      described_class.new(runner: Empeira::Execution::Runner.new, project: Pathname(@directory))
                     .prepare([{ 'name' => 'profile', 'remote' => 'git@private-alias:profile.git' }], directory: target)
    end.not_to output.to_stderr_from_any_process
    expect(target.children.size).to eq(1)
    expect(target.children.first.join('HEAD')).to be_file
    expect(target.children.first.join('hooks')).not_to exist
    call = JSON.parse(File.read(trace))
    expect(call.fetch('agent')).to eq(environment.fetch('SSH_AUTH_SOCK'))
    expect(call.fetch('arguments')).to include('git@private-alias', "git-upload-pack 'profile.git'")
    result = Empeira::Execution::Runner.new.run('git',
                                                arguments: ['-C', target.children.first.to_s, 'show-ref'])
    expect(result.stdout).to include(source.commit)
  ensure
    ENV.update(previous) if previous
  end
end
