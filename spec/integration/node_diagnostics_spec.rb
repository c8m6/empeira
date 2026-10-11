# frozen_string_literal: true

require_relative '../support/diagnostic_access'

RSpec.describe 'Real root diagnostics and recovery cleanup', :integration do
  include LiveDiagnosticAccess

  let(:engine) { ENV.fetch('EMPEIRA_DIAGNOSTIC_RUNTIME', 'docker') }
  let(:project) { File.join(@directory, 'control') }
  let(:locations) do
    Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'),
                                     environment: { 'XDG_CACHE_HOME' => File.join(Dir.home, '.cache') })
  end
  let(:name) { 'diagnostic.example.test' }

  def app(recovery: false, recovery_path: nil)
    Empeira::Application.new(project_path: project, locations: locations, recovery: recovery,
                             recovery_path: recovery_path, overrides: { 'runtime' => { 'container_engine' => engine } })
  end

  def record
    Empeira::Infrastructure::Store.new(context: app.context).load.fetch('nodes').fetch(name)
  end

  before do
    skip 'Set EMPEIRA_DIAGNOSTIC_INTEGRATION=1 for isolated real diagnostics and recovery' unless
      ENV['EMPEIRA_DIAGNOSTIC_INTEGRATION'] == '1'

    initialize_project(project)
    FileUtils.mkdir_p(File.join(project, 'manifests'))
    init = engine == 'podman' ? 'systemd' : 'process'
    File.write(File.join(project, '.empeira.yaml'), YAML.dump('puppetdb' => { 'enabled' => false },
                                                              'runtime' => { 'container_engine' => engine },
                                                              'node_defaults' => { 'init' => init }))
    @saved_path = app.context.workspace.path.to_s
    File.write(File.join(project, 'manifests/site.pp'), <<~PUPPET)
      user { 'root': ensure => present, password => '!' }
      if $facts['empeira']['provider'] == 'vm' {
        service { 'ssh': ensure => stopped, enable => false }
        service { 'puppet': ensure => stopped, enable => false }
        service { 'ssh.socket': ensure => stopped, enable => false }
      } else {
        #{if engine == 'podman'
            "service { 'ssh': ensure => stopped, enable => false }"
          else
            %q(file { '/etc/ssh/sshd_config': content => "InvalidDiagnosticFixture yes\n" })
          end}
      }
      file { '/tmp/diagnostic-puppet': content => $facts['empeira']['provider'] }
    PUPPET
  end

  after do
    app(recovery: true, recovery_path: @saved_path).infrastructure.destroy if @saved_path
  end

  %w[container vm].each do |provider|
    it "keeps #{provider} root diagnostics working after Puppet locks root and disables SSHD" do
      selected = ENV.fetch('EMPEIRA_DIAGNOSTIC_PROVIDERS', 'container,vm').split(',')
      skip "Provider #{provider} not selected" unless selected.include?(provider)

      Empeira::VM.registry.build('qemu', context: app.context, runner: app.runner).preflight! if provider == 'vm'
      app.infrastructure.up
      app.run_node(hostname: name, provider: provider)
      application = app
      runtime = Empeira::Runtime.registry.build(engine, context: application.context, runner: application.runner)
      if provider == 'vm'
        @guest = vm_guest(application)
        expect(@guest.run(record, ['sh', '-c', 'test "$(getent shadow root | cut -d : -f 2)" = "!"'])).to be_success
        expect(@guest.run(record, %w[systemctl is-active ssh.service])).not_to be_success
        expect(@guest.run(record, %w[id -u]).stdout.strip).to eq('0')
      elsif engine == 'docker'
        definition = Empeira::Node::Definition.new(hostname: name, workspace: application.context.workspace)
        resource = runtime.inspect_service(definition, expected_id: record.fetch('id'))
        expect(runtime.service_exec(resource, %w[/usr/sbin/sshd -t])).not_to be_success
      end
      commands = "id -u\nstty size\ncat /tmp/diagnostic-puppet\nexit 7\n"
      result, transcript = diagnostic_shell(application, name: name, commands: commands)
      expect(result.exit_status).to eq(7), transcript
      clean = transcript.gsub(%r{\e\[[0-?]*[ -/]*[@-~]}, '').delete("\r")
      expect(clean).to match(/^0$/)
      expect(transcript).to include('29 101', provider)
      verify_exec(application, provider, runtime)
      verify_exec_interrupt(application, provider, runtime)
      verify_parallel_vm(application) if provider == 'vm'
      verify_terminal_controls(application) if provider == 'vm'
      if provider == 'vm' || engine == 'podman'
        application.nodes.stop(name: name)
        application.nodes.start(name: name)
        verify_exec(application, provider, runtime)
      end
      if provider == 'vm'
        begin
          @guest.run(record, %w[systemctl stop empeira-management.service])
        rescue Empeira::VM::Guest::TransportError
          # Deliberately stopping the current transport may make its own completion unknowable.
        end
        expect { @guest.run(record, %w[id -u]) }.to raise_error(Empeira::Error)
        input = Tempfile.new('detach')
        input.write("\x1d")
        input.rewind
        output = Tempfile.new('console')
        allow(application.runner).to receive(:console).and_wrap_original do |method, path, **options|
          method.call(path, **options, input: input, output: output)
        end
        expect(application.nodes.console(name: name)).to be_success
      end
      # Preserve native identity while simulating a newer incompatible control layout and missing repository.
      store = Empeira::Infrastructure::Store.new(context: application.context, recovery: true)
      state = store.load
      server = Empeira::Services::Definition.new(key: 'server', workspace: application.context.workspace)
      runtime.remove_service(server, expected_id: state.dig('control_plane', 'services', 'server', 'id'))
      state['schema_version'] = 999
      state.fetch('nodes').fetch(name)['management_layout'] = 999 if provider == 'vm'
      store.with_lock { store.write(state) }
      FileUtils.remove_entry(project)
      recovered = app(recovery: true, recovery_path: @saved_path)
      expect(recovered.nodes.destroy(name: name).changed).to be(true)
      expect(store.load.fetch('nodes')).to be_empty
      recovered.infrastructure.destroy
      expect(store.load).to be_nil
      expect(recovered.infrastructure.destroy.changed).to be(false)
    ensure
      input&.close!
      output&.close!
    end
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Observe exact exits and timeout recovery through both real providers.
  def verify_exec(application, _provider, _runtime)
    stdout = Tempfile.new('exec-stdout')
    stderr = Tempfile.new('exec-stderr')
    result = application.nodes.exec(name: name, arguments: ['sh', '-c', 'printf out; printf err >&2; exit 255'],
                                    output: stdout, error: stderr)
    expect(result.exit_status).to eq(255)
    stdout.rewind
    stderr.rewind
    expect(stdout.read).to eq('out')
    expect(stderr.read).to eq('err')

    stdout.truncate(0)
    stdout.rewind
    literal = 'a; $(printf interpreted) * --timeout 1'
    expect(application.nodes.exec(name: name, arguments: ['printf', '%s', literal], output: stdout)).to be_success
    stdout.rewind
    expect(stdout.read).to eq(literal)
    expect(application.nodes.exec(name: name, arguments: ['true; echo unintended'],
                                  error: stderr).exit_status).to eq(127)

    expect(application.nodes.exec(name: name, arguments: ['sh', '-c', 'exit 6']).exit_status).to eq(6)
    result = application.nodes.exec(name: name, arguments: ['sh', '-c', 'sleep 30 & wait'], timeout: 0.3)
    expect(result.timed_out).to be(true)
    expect(application.nodes.exec(name: name, arguments: ['true'])).to be_success
  ensure
    stdout&.close!
    stderr&.close!
  end

  # rubocop:disable-next Metrics/AbcSize -- Keep both session consumers alive until independent outputs are verified.
  def verify_parallel_vm(_application)
    state = record
    first_output = Tempfile.new('parallel-one')
    second_output = Tempfile.new('parallel-two')
    threads = [first_output, second_output].each_with_index.map do |output, index|
      Thread.new { @guest.stream(state, ['sh', '-c', "printf session#{index}; sleep 0.5"], output: output) }
    end
    expect(threads.map(&:value)).to all(be_success)
    [first_output, second_output].each_with_index do |output, index|
      output.rewind
      expect(output.read).to eq("session#{index}")
    end
  ensure
    threads&.each { |thread| thread.kill.join }
    [first_output, second_output].compact.each(&:close!)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Exercise real foreground jobs, resize and fullscreen output in one owned PTY.
  def verify_terminal_controls(application)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('TERM', 'xterm').and_return('xterm')
    controller = lambda do |master, terminal, transcript|
      master.write("printf 'READY_%s\\n' GUEST\n")
      await_terminal(transcript, 'READY_GUEST')
      expect(@guest.run(record, %w[id -u]).stdout.strip).to eq('0')
      terminal.winsize = [45, 117]
      Process.kill('WINCH', Process.pid)
      master.write("stty size\nprintf 'RESIZED_%s\\n' GUEST\n")
      await_terminal(transcript, 'RESIZED_GUEST')
      expect(transcript).to include('45 117')
      master.write("top -d 0.2\n")
      await_terminal(transcript, 'Tasks:')
      master.write('q')
      sleep 0.2
      master.write("printf 'TOP_%s\\n' DONE\n")
      await_terminal(transcript, 'TOP_DONE')
      master.write("sleep 30\n")
      sleep 0.2
      master.write("\x1a")
      await_terminal(transcript, 'Stopped')
      master.write("fg\n")
      sleep 0.2
      master.write("\x03")
      master.write("printf 'SIGNALS_%s\\n' DONE\n")
      await_terminal(transcript, 'SIGNALS_DONE')
      master.write("\x04")
    end
    result, transcript = diagnostic_shell(application, name: name, commands: '', controller: controller)
    expect(result).to be_success, transcript
    expect(transcript).to include("\e[")
    expect(@guest.run(record, ['sh', '-c', 'test ! -s /root/.bash_history'])).to be_success
    expect(@guest.run(record, %w[true])).to be_success
  end

  def await_terminal(transcript, marker)
    Timeout.timeout(15) { sleep 0.01 until transcript.include?(marker) }
  rescue Timeout::Error
    raise "Missing terminal marker #{marker}: #{transcript}"
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Cancellation is confirmed against both owned guest process IDs before cleanup.
  def verify_exec_interrupt(application, provider, runtime)
    path = '/tmp/empeira-diagnostic-pids'
    worker = Thread.new do
      application.nodes.exec(name: name,
                             arguments: ['sh', '-c',
                                         "echo $$ > #{path}; sleep 30 & echo $! >> #{path}; wait"])
    rescue Interrupt
      :interrupted
    end
    definition = Empeira::Node::Definition.new(hostname: name, workspace: application.context.workspace)
    resource = runtime.inspect_service(definition, expected_id: record.fetch('id')) if provider == 'container'
    Timeout.timeout(15) do
      loop do
        observed = provider == 'vm' ? @guest.run(record, ['cat', path]) : runtime.service_exec(resource, ['cat', path])
        break if observed.success? && observed.stdout.lines.length == 2

        sleep 0.05
      end
    end
    worker.raise(Interrupt)
    expect(worker.join(10)).not_to be_nil
    expect(worker.value).to eq(:interrupted)
    verify = <<~SH
      while read pid; do
        if test -r /proc/$pid/stat; then
          test "$(cut -d ' ' -f 3 /proc/$pid/stat)" = Z || exit 1
        fi
      done < #{path}
      rm #{path}
    SH
    expect(application.nodes.exec(name: name, arguments: ['sh', '-c', verify])).to be_success
  ensure
    [worker].compact.each { |thread| thread.kill.join }
  end
end
