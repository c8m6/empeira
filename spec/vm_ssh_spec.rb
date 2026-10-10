# frozen_string_literal: true

RSpec.describe Empeira::VM::SSH do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:transport) { described_class.new(context: nil, runner: runner, cloud_init: nil) }
  let(:record) { { 'ssh_layout' => Empeira::VM::Management::VERSION } }

  before do
    File.write(File.join(@directory, 'private-source'), 'synthetic upload')
    allow(transport).to receive(:binary).with('scp').and_return('scp')
    allow(transport).to receive(:scp_options).and_return([])
    allow(transport).to receive(:run).and_return(success)
  end

  [false, true].each do |timed_out|
    it "removes partial upload staging after SCP failure (timeout=#{timed_out}) without installing it" do
      path = nil
      allow(runner).to receive(:run) do |_binary, arguments:, **|
        path = arguments.last.split(':', 2).last
        success.with(exit_status: 1, timed_out: timed_out)
      end
      expect { transport.copy_to(record, File.join(@directory, 'private-source'), '/var/tmp/private') }
        .to raise_error(Empeira::Error, /Cannot copy/)
      expect(transport).to have_received(:run).with(record, ['rm', '-f', '--', path])
      expect(transport).not_to have_received(:run).with(record, array_including('install'))
    end
  end

  it 'fails closed when upload succeeds but staging removal fails' do
    allow(runner).to receive(:run).and_return(success)
    allow(transport).to receive(:run).with(record, array_including('rm')).and_return(success.with(exit_status: 1))
    expect { transport.copy_to(record, File.join(@directory, 'private-source'), '/var/tmp/private', mode: '0600') }
      .to raise_error(Empeira::Error, /staging cleanup/)
    expect(transport).to have_received(:run).with(record, array_including('sh', '-eu', '0600'))
  end

  it 'attempts staging removal even if the transfer raises an exception' do
    allow(runner).to receive(:run).and_raise(Empeira::Error, 'transfer interrupted')
    expect do
      transport.copy_to(record, File.join(@directory, 'private-source'), '/var/tmp/private')
    end.to raise_error(Empeira::Error, /interrupted/)
    expect(transport).to have_received(:run).with(record, array_including('rm', '-f', '--'))
  end

  it 'stages root SCP uploads only in the verified private management directory' do
    modern = record
    path = nil
    allow(runner).to receive(:run) do |_binary, arguments:, **|
      path = arguments.last.split(':', 2).last
      success
    end
    transport.copy_to(modern, File.join(@directory, 'private-source'), '/var/tmp/private')
    expect(transport).to have_received(:run).with(modern, ['true'])
    expect(path).to start_with('/etc/empeira/management/uploads/.empeira-copy-')
    expect(runner).to have_received(:run).with('scp', arguments: array_including("root@127.0.0.1:#{path}"), timeout: 30)
    expect(transport).to have_received(:run).with(modern, ['rm', '-f', '--', path])
  end

  it 'streams directly as root through the checked normal guest mount namespace' do
    allow(transport).to receive(:binary).with('ssh').and_return('ssh')
    allow(transport).to receive(:options).and_return([])
    expect(runner).to receive(:stream).with('ssh', arguments: ['root@127.0.0.1',
                                                               "#{Empeira::VM::Management::CHECK} && " \
                                                               'nsenter --target 1 --mount -- puppet agent --test'])
    transport.stream(record, %w[puppet agent --test])
  end

  it 'does not attempt authentication or uploads for an incompatible layout' do
    expect(runner).not_to receive(:run)
    expect { transport.copy_to({}, File.join(@directory, 'private-source'), '/var/tmp/private') }
      .to raise_error(Empeira::Error, /Incompatible VM management SSH layout/)
  end

  it 'verifies uploaded and installed content and refuses corrupt staging before installation' do
    source = Pathname(@directory).join('private-source')
    destination = Pathname(@directory).join('installed')
    execute = lambda do |digest|
      Empeira::Execution::Runner.new.run('sh', arguments: ['-eu', '-c', transport.send(:upload_script),
                                                           'empeira-upload', source.to_s, destination.to_s,
                                                           '0600', digest])
    end
    expect(execute.call('0' * 64)).not_to be_success
    expect(destination).not_to exist
    expect(execute.call(Digest::SHA256.file(source).hexdigest)).to be_success
    expect(destination.read).to eq(source.read)
    expect(destination.stat.mode & 0o777).to eq(0o600)
  end

  context 'guest command completion' do
    before do
      allow(transport).to receive(:binary).with('ssh').and_return('ssh')
      allow(transport).to receive(:options).and_return([])
      allow(transport).to receive(:run).and_call_original
      bin = Pathname(@directory).join('bin')
      bin.mkpath
      @checker = Pathname(@directory).join('management-check')
      @checker.write("#!/bin/sh\nexit 0\n")
      @checker.chmod(0o700)
      bin.join('nsenter').write("#!/bin/sh\nshift 4\nexec \"$@\"\n")
      bin.join('nsenter').chmod(0o700)
      allow(runner).to receive(:run) do |_binary, arguments:, timeout:|
        expect(arguments).to include('root@127.0.0.1')
        expect(arguments.last).to include('nsenter --target 1 --mount --')
        expect(arguments.last).not_to include('sudo')
        command = arguments.last.gsub(Empeira::VM::Management::CHECK, @checker.to_s)
        Empeira::Execution::Runner.new.run('/bin/sh', arguments: ['-c', command],
                                                      environment: { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}" },
                                                      timeout: timeout)
      end
    end

    [0, 1, 255].each do |status|
      it "preserves native guest stdout, stderr and exit #{status} independently of SSH status" do
        result = transport.run(record, ['sh', '-c', "printf native-out; printf native-err >&2; exit #{status}"])
        expect(result.stdout).to eq('native-out')
        expect(result.stderr).to include('native-err')
        expect(result.stderr).not_to include('EMPEIRA_GUEST_EXIT_')
        expect(result.exit_status).to eq(status)
        expect(result.timed_out).to be(false)
        expect(result.stderr).to include('SSH transport completed; guest command failed') unless status.zero?
      end
    end

    it 'quotes guest arguments literally without evaluating metacharacters' do
      text = "spaces; $(exit 88) `exit 89` 'quoted'"
      expect(transport.run(record, ['printf', '%s', text]).stdout).to eq(text)
    end

    context 'with separate management SSH' do
      it 'preserves native command status after verifying management and entering the guest mount namespace' do
        result = transport.run(record, ['sh', '-c', 'printf native-command; exit 23'])
        expect(result.stdout).to eq('native-command')
        expect(result.exit_status).to eq(23)
      end

      it 'refuses to execute guest operations when the management guard fails' do
        @checker.write("#!/bin/sh\necho 'changed management policy' >&2\nexit 78\n")
        result = transport.run(record, %w[printf must-not-run])
        expect(result.stdout).to be_empty
        expect(result.exit_status).to eq(78)
        expect(result.stderr).to include('changed management policy')
      end
    end

    {
      'Connection reset by peer' => true,
      'ssh: connect to host 127.0.0.1 port 22: Connection refused' => true,
      'Permission denied (publickey).' => false,
      'REMOTE HOST IDENTIFICATION HAS CHANGED! Connection closed' => false
    }.each do |stderr, transient|
      it "classifies #{stderr} without confusing it with a guest exit" do
        allow(runner).to receive(:run).and_return(success.with(exit_status: 255, stderr: stderr))
        expect { transport.run(record, %w[rm --force -- /var/tmp/backup]) }
          .to raise_error(described_class::TransportError) do |error|
            expect(error.transient?).to be(transient)
            expect(error.message).to include('SSH transport failed', 'Operation: VM guest rm',
                                             'Exit code: 255', 'Timeout: false', stderr)
            expect(error.cause).to be_nil
          end
      end
    end

    it 'reports timeouts as unknown completion without treating a running guest command as retryable' do
      allow(runner).to receive(:run).and_return(success.with(exit_status: nil, timed_out: true,
                                                             stdout: 'partial native output'))
      expect { transport.run(record, %w[apt-get install synthetic]) }
        .to raise_error(described_class::TransportError) do |error|
          expect(error.transient?).to be(false)
          expect(error.message).to include('Exit code: unavailable', 'Timeout: true', 'partial native output')
        end
    end

    it 'rejects missing completion status even when the SSH process reports success' do
      allow(runner).to receive(:run).and_return(success)
      expect { transport.run(record, %w[rm --force -- /var/tmp/backup]) }
        .to raise_error(Empeira::Error, /completion status is unavailable/)
    end

    it 'redacts native transport diagnostics before exposing them' do
      text = "Connection reset by peer\nAuthorization: Basic synthetic\npassword=synthetic-password\n" \
             "-----BEGIN PRIVATE KEY-----\nsynthetic-private-material\n-----END PRIVATE KEY-----"
      allow(runner).to receive(:run).and_return(success.with(exit_status: 255, stderr: text))
      expect { transport.run(record, %w[rm --force -- /var/tmp/backup]) }
        .to raise_error(Empeira::Error) do |error|
          expect(error.full_message).not_to include('synthetic-password', 'synthetic-private-material',
                                                    'Basic synthetic')
        end
    end
  end
end
