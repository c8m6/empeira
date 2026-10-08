# frozen_string_literal: true

RSpec.describe Empeira::Execution::Runner do
  subject(:runner) { described_class.new }

  it 'captures stdout, stderr and exit status independently' do
    result = runner.run(RbConfig.ruby, arguments: ['-e', '$stdout.write "out"; $stderr.write "err"; exit 7'])
    expect(result.stdout).to eq('out')
    expect(result.stderr).to eq('err')
    expect(result.exit_status).to eq(7)
    expect(result).not_to be_success
    expect(result.timed_out).to be(false)
  end

  it 'passes environment and working directory without modifying the parent process' do
    code = 'require "json"; puts JSON.generate([Dir.pwd, ENV.fetch("EMPEIRA_TEST_VALUE")])'
    result = runner.run(RbConfig.ruby, arguments: ['-e', code], environment: { 'EMPEIRA_TEST_VALUE' => 'a b' },
                                       directory: @directory)
    expect(result).to be_success
    expect(JSON.parse(result.stdout)).to eq([File.realpath(@directory), 'a b'])
    expect(ENV).not_to have_key('EMPEIRA_TEST_VALUE')
  end

  it 'never interprets metacharacters in arguments as shell syntax' do
    values = ['a b', '; exit 88', '$(exit 89)', '`exit 90`', '*', 'a"b']
    result = runner.run(RbConfig.ruby, arguments: ['-rjson', '-e', 'puts JSON.generate(ARGV)', '--', *values])
    expect(result).to be_success
    expect(JSON.parse(result.stdout)).to eq(values)
  end

  it 'does not use shell fallback for a single executable string' do
    expect { runner.run('echo dangerous; exit 0') }.to raise_error(Empeira::ExecutionError, /could not be executed/)
  end

  it 'drains both streams concurrently beyond pipe capacity' do
    result = runner.run(RbConfig.ruby, arguments: ['-e', '$stdout.write "x" * 200_000; $stderr.write "y" * 200_000'],
                                       timeout: 10)
    expect(result).to be_success
    expect(result.stdout.size).to eq(200_000)
    expect(result.stderr.size).to eq(200_000)
  end

  it 'closes stdin so children waiting for EOF can finish' do
    result = runner.run(RbConfig.ruby, arguments: ['-e', 'puts STDIN.read.empty?'], timeout: 5)
    expect(result.stdout.strip).to eq('true')
  end

  it 'observes captured output before completion without forwarding it to the terminal' do
    chunks = []
    observed = Queue.new
    code = '$stdout.sync = true; puts "module"; sleep 0.3; STDERR.write "private\n"'
    runner_thread = Thread.new do
      runner.run(RbConfig.ruby, arguments: ['-e', code],
                                on_stdout: lambda { |chunk|
                                  chunks << chunk
                                  observed << true
                                }, timeout: 5)
    end
    Timeout.timeout(5) { observed.pop }
    expect(runner_thread).to be_alive
    result = runner_thread.value
    expect(chunks.join).to eq(result.stdout)
    expect(result.stderr).to eq("private\n")
  ensure
    runner_thread&.kill&.join
  end

  it 'buffers foreground output while inheriting authentication input and process group' do
    incoming, input = IO.pipe
    input.puts 'synthetic-response'
    input.close
    code = 'puts STDIN.gets; puts Process.getpgrp; STDERR.write "x" * 200_000; exit 7'
    result = nil
    expect { result = runner.buffered(RbConfig.ruby, arguments: ['-e', code], input: incoming) }
      .not_to output.to_stdout_from_any_process
    expect(result.stdout).to eq("synthetic-response\n#{Process.getpgrp}\n")
    expect(result.stderr).to eq('x' * 200_000)
    expect(result.exit_status).to eq(7)
  ensure
    incoming&.close
  end

  it 'kills and reaps a timed out child without reporting success' do
    result = runner.run(RbConfig.ruby, arguments: ['-e', 'sleep 30'], timeout: 0.2)
    expect(result.timed_out).to be(true)
    expect(result.exit_status).to be_nil
    expect(result).not_to be_success
  end

  it 'times out descendants holding output pipes after the parent exits' do
    result = runner.run(RbConfig.ruby, arguments: ['-e', 'fork { sleep 30 }; exit! 0'], timeout: 0.2)
    expect(result.timed_out).to be(true)
  end

  it 'redacts all argument and environment values from debug output' do
    messages = []
    logger = double('logger')
    allow(logger).to receive(:debug) { |message| messages << message }
    runner = described_class.new(logger: logger)
    result = runner.run(RbConfig.ruby, arguments: ['-e', 'puts ARGV.first', 'synthetic-secret'],
                                       environment: { 'EMPEIRA_TEST_TOKEN' => 'synthetic-token' })
    expect(result.stdout).to include('synthetic-secret')
    expect(messages.to_s).not_to include('synthetic-secret', 'synthetic-token', 'puts ARGV')
    expect(messages.first[:environment]['EMPEIRA_TEST_TOKEN']).to eq('[REDACTED]')
  end

  [0, -1, '5', Float::INFINITY].each do |timeout|
    it "rejects invalid timeout #{timeout.inspect}" do
      expect { runner.run(RbConfig.ruby, timeout: timeout) }.to raise_error(Empeira::ExecutionError, /Timeout/)
    end
  end

  it 'reports unavailable executables without leaking the executable value' do
    expect { runner.run(File.join(@directory, 'synthetic-secret')) }
      .to raise_error(Empeira::ExecutionError) { |error| expect(error.message).not_to include('synthetic-secret') }
  end
  it 'removes sensitive process data from every exception representation' do
    marker = 'synthetic-private-command-value'
    begin
      runner.run(File.join(@directory, marker))
    rescue Empeira::ExecutionError => e
      expect(e.cause).to be_nil
      expect([e.message, e.inspect, e.full_message].join).not_to include(marker)
      expect(e.message).to include('Errno::ENOENT')
    else
      raise 'Expected a launch failure'
    end
  end

  it 'redacts failed working-directory paths from diagnostic exception chains' do
    expect { runner.run(RbConfig.ruby, directory: File.join(@directory, 'synthetic-private-directory')) }
      .to raise_error(Empeira::ExecutionError) do |error|
        expect(error.cause).to be_nil
        expect(error.full_message).not_to include('synthetic-private-directory')
      end
  end

  [Interrupt, IOError].each do |error_class|
    it "cleans the owned group on #{error_class} after its direct child has exited" do
      leader = nil
      allow(runner).to receive(:collect) do |process, _streams, _timeout|
        process.value
        leader = process.pid
        expect(process).not_to be_alive
        raise error_class, 'Synthetic cancellation'
      end
      kill = Process.method(:kill)
      expect(Process).to receive(:kill) do |signal, target|
        expect(signal).to eq('KILL')
        expect(target).to eq(-leader)
        # Exercise real OS cleanup, with the exact group owned by this invocation.
        kill.call(signal, target)
      end
      expect { runner.run(RbConfig.ruby, arguments: ['-e', 'fork { sleep 30 }; exit! 0']) }
        .to raise_error(error_class, 'Synthetic cancellation')
    end
  end

  it 'does not signal process groups after normal completion' do
    expect(runner).not_to receive(:terminate)
    expect(runner.run(RbConfig.ruby, arguments: ['-e', 'exit 0'])).to be_success
  end

  it 'streams output before the child exits without retaining it in the result' do
    incoming, input = IO.pipe
    output, outgoing = IO.pipe
    worker = Thread.new do
      runner.stream(RbConfig.ruby, arguments: ['-e', '$stdout.sync = true; puts "ready"; STDIN.gets; exit 7'],
                                   input: incoming, output: outgoing, error: outgoing)
    end
    expect(output.wait_readable(5)).not_to be_nil
    expect(output.gets).to eq("ready\n")
    expect(worker).to be_alive
    input.puts 'continue'
    expect(worker.join(5)).not_to be_nil
    expect(worker.value).to have_attributes(stdout: '', stderr: '', exit_status: 7)
  ensure
    worker&.kill&.join
    [incoming, input, output, outgoing].compact.each(&:close)
  end

  it 'reaps an interrupted streaming child and preserves the interruption' do
    child = nil
    allow(Process).to receive(:wait2) do |pid|
      child = pid
      raise Interrupt, 'synthetic interruption'
    end
    expect { runner.stream(RbConfig.ruby, arguments: ['-e', 'sleep 30']) }
      .to raise_error(Interrupt, 'synthetic interruption')
    expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
  end
end
