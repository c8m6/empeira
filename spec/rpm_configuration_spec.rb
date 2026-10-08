# frozen_string_literal: true

RSpec.describe Empeira::Node::RpmConfiguration do
  let(:root) { Pathname(@directory).join('guest') }
  let(:repos) { root.join('etc/yum.repos.d') }
  let(:dnf) { root.join('etc/dnf') }
  let(:backup) { root.join('var/tmp/empeira-dnf-before-bootstrap.tar') }
  let(:runner) { Empeira::Execution::Runner.new }
  let(:execute) { ->(arguments) { runner.run(arguments.first, arguments: arguments.drop(1)) } }

  before do
    repos.mkpath
    dnf.mkpath
    backup.dirname.mkpath
    repos.join('base.repo').write("[base]\nbaseurl=https://repo.example.net/base\n")
    dnf.join('dnf.conf').write("[main]\ngpgcheck=1\n")
  end

  it 'restores the original DNF repository and main configuration after success' do
    expected = tree
    described_class.new(os: 'rocky', execute: execute, root: root, backup: backup).preserve do
      repos.join('base.repo').delete
      repos.join('empeira-agent.repo').write("[empeira-agent]\n")
      dnf.join('dnf.conf').write("[main]\ngpgcheck=0\n")
    end
    expect(tree).to eq(expected)
    expect(backup).not_to exist
  end

  it 'restores the original DNF configuration after installation failure' do
    expected = tree
    expect do
      described_class.new(os: 'almalinux', execute: execute, root: root, backup: backup).preserve do
        repos.join('empeira-agent.repo').write("[empeira-agent]\n")
        raise Empeira::Error, 'agent installation failed'
      end
    end.to raise_error(Empeira::Error, 'agent installation failed')
    expect(tree).to eq(expected)
  end

  it 'retains the backup and prevents Puppet when DNF configuration restoration fails' do
    failing = lambda do |arguments|
      next Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false) if
        arguments.include?('--compare')

      execute.call(arguments)
    end
    started = false
    expect do
      described_class.new(os: 'oraclelinux', execute: failing, root: root, backup: backup).preserve do
        repos.join('empeira-agent.repo').write("[empeira-agent]\n")
      end
      started = true
    end.to raise_error(Empeira::Error, /Cannot restore and verify.*Puppet was not run/)
    expect(started).to be(false)
    expect(backup).to exist
  end

  def tree
    [repos, dnf].flat_map { |directory| directory.glob('**/*') }.sort.to_h do |path|
      [path.relative_path_from(root).to_s, path.file? ? path.binread : nil]
    end
  end
end
