# frozen_string_literal: true

RSpec.describe Empeira::Node::AptConfiguration do
  let(:root) { Pathname(@directory).join('guest') }
  let(:apt) { root.join('etc/apt') }
  let(:backup) { root.join('var/tmp/empeira-apt-before-bootstrap.tar') }
  let(:runner) { Empeira::Execution::Runner.new }
  let(:execute) do
    lambda do |arguments|
      runner.run(arguments.first, arguments: arguments.drop(1))
    end
  end

  before do
    apt.join('sources.list.d').mkpath
    backup.dirname.mkpath
    apt.join('sources.list').write("deb http://archive.ubuntu.com/ubuntu noble main\n")
    apt.join('sources.list.d/ubuntu.sources').write(
      "Types: deb\nURIs: http://security.ubuntu.com/ubuntu\nSuites: noble-security\nComponents: main\n"
    )
    apt.join('apt.conf.d').mkpath
    apt.join('apt.conf.d/01-base').write("Acquire::Retries \"3\";\n")
  end

  %w[ubuntu debian].each do |distribution|
    it "restores #{distribution} legacy and deb822 sources exactly before Puppet" do
      before = tree
      described_class.new(os: distribution, execute: execute, root: root, backup: backup).preserve do
        apt.join('sources.list').write("deb https://temporary.example.test/internal stable main\n")
        apt.join('sources.list.d/ubuntu.sources').delete
        apt.join('sources.list.d/agent.list').write("deb https://agent.example.test noble agent\n")
        apt.join('apt.conf.d/99-temporary').write("Acquire::http::Proxy \"http://temporary\";\n")
      end
      puppet_sources = tree

      expect(puppet_sources).to eq(before)
      expect(apt.join('sources.list.d/agent.list')).not_to exist
      expect(backup).not_to exist
    end
  end

  it 'restores after a bootstrap operation fails' do
    before = tree
    expect do
      described_class.new(os: 'ubuntu', execute: execute, root: root, backup: backup).preserve do
        apt.join('sources.list').write("deb https://temporary.example.test/internal stable main\n")
        raise Empeira::Error, 'agent installation failed'
      end
    end.to raise_error(Empeira::Error, 'agent installation failed')
    expect(tree).to eq(before)
    expect(backup).not_to exist
  end

  it 'fails closed and retains the VM backup when restoration cannot be verified' do
    failing_execute = lambda do |arguments|
      if arguments.include?('--compare')
        Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 1, timed_out: false)
      else
        execute.call(arguments)
      end
    end
    puppet_started = false

    expect do
      described_class.new(os: 'ubuntu', execute: failing_execute, root: root, backup: backup).preserve do
        apt.join('sources.list.d/agent.list').write("deb https://agent.example.test noble agent\n")
      end
      puppet_started = true
    end.to raise_error(Empeira::Error, /Cannot restore and verify.*Puppet was not run/)
    expect(puppet_started).to be(false)
    expect(backup).to exist
  end

  it 'does not inspect or change APT configuration for an RPM guest' do
    expect(execute).not_to receive(:call)
    yielded = false
    described_class.new(os: 'rocky', execute: execute, root: root, backup: backup).preserve { yielded = true }
    expect(yielded).to be(true)
  end

  %w[--create --extract --compare].each do |step|
    it "reports #{step} failures and never continues to Puppet" do
      failing_execute = lambda do |arguments|
        if arguments.include?(step)
          Empeira::Execution::Result.new(stdout: 'partial archive output', stderr: 'tar: synthetic native failure',
                                         exit_status: 2, timed_out: false)
        else
          execute.call(arguments)
        end
      end
      puppet_started = false
      operation = lambda do
        described_class.new(os: 'ubuntu', execute: failing_execute, root: root, backup: backup).preserve { nil }
        puppet_started = true
      end
      expect(&operation).to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('Operation:', step, 'Exit code: 2', 'Timeout: false',
                                         'partial archive output', 'tar: synthetic native failure')
      end
      expect(puppet_started).to be(false)
      expect(backup).to exist unless step == '--create'
    end
  end

  it 'does not retry native backup-removal failures and retains diagnostics and the verified archive' do
    removals = 0
    failing_execute = lambda do |arguments|
      if arguments == ['rm', '--force', '--', backup.to_s]
        removals += 1
        Empeira::Execution::Result.new(stdout: '', stderr: 'rm: Permission denied', exit_status: 1, timed_out: false)
      else
        execute.call(arguments)
      end
    end
    original = tree
    expect do
      described_class.new(os: 'ubuntu', execute: failing_execute, root: root, backup: backup).preserve { nil }
    end.to raise_error(Empeira::Error, /Cannot remove.*Exit code: 1.*rm: Permission denied/m)
    expect(removals).to eq(1)
    expect(tree).to eq(original)
    expect(backup).to exist
  end

  [false, true].each do |deleted_before_disconnect|
    it "retries only backup removal after a transient SSH disconnect (already deleted=#{deleted_before_disconnect})" do
      removals = 0
      installations = 0
      retries = []
      recovering_execute = lambda do |arguments|
        if arguments == ['rm', '--force', '--', backup.to_s]
          removals += 1
          if removals == 1
            execute.call(arguments) if deleted_before_disconnect
            raise Empeira::VM::Guest::TransportError.new('Connection reset by peer', transient: true)
          end
        end
        execute.call(arguments)
      end
      original = tree
      described_class.new(os: 'ubuntu', execute: recovering_execute, root: root, backup: backup,
                          on_retry: ->(message) { retries << message }).preserve do
        installations += 1
        apt.join('sources.list').write('temporary source')
      end
      expect(installations).to eq(1)
      expect(removals).to eq(2)
      expect(retries.size).to eq(1)
      expect(retries.first).to include('Retrying only', 'Connection reset by peer')
      expect(tree).to eq(original)
      expect(backup).not_to exist
    end
  end

  it 'bounds persistent transport failures and keeps Puppet and runtime networking disabled' do
    removals = 0
    failing_execute = lambda do |arguments|
      if arguments == ['rm', '--force', '--', backup.to_s]
        removals += 1
        raise Empeira::VM::Guest::TransportError.new('Connection reset by peer', transient: true)
      end
      execute.call(arguments)
    end
    continued = false
    expect do
      described_class.new(os: 'ubuntu', execute: failing_execute, root: root, backup: backup).preserve { nil }
      continued = true
    end.to raise_error(Empeira::Error, /Cannot remove.*Connection reset/m)
    expect(removals).to eq(2)
    expect(continued).to be(false)
    expect(backup).to exist
  end

  it 'does not retry unknown completion after a timeout' do
    removals = 0
    failing_execute = lambda do |arguments|
      if arguments == ['rm', '--force', '--', backup.to_s]
        removals += 1
        raise Empeira::VM::Guest::TransportError.new('Timeout: true', timed_out: true)
      end
      execute.call(arguments)
    end
    expect do
      described_class.new(os: 'ubuntu', execute: failing_execute, root: root, backup: backup).preserve { nil }
    end.to raise_error(Empeira::Error, /Timeout: true/)
    expect(removals).to eq(1)
  end

  def tree
    apt.glob('**/*', File::FNM_DOTMATCH).sort.to_h do |path|
      relative = path.relative_path_from(apt).to_s
      stat = path.lstat
      value = path.file? ? path.binread : nil
      [relative, [stat.ftype, stat.mode & 0o7777, value]]
    end
  end
end
