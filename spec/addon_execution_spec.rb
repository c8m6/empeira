# frozen_string_literal: true

require_relative 'support/addon_source'
require 'empeira/cli/main'
require 'pty'

RSpec.describe 'Standalone addon execution' do
  include AddonFixture

  let(:source) { AddonSource.new(@directory).start }
  before { configure_addon }
  after { source.close }

  it 'automatically installs, preserves opaque argv and cwd, and returns stdout/stderr without shell interpolation' do
    source.script("require 'yaml'; puts YAML.dump('argv' => ARGV, 'cwd' => Dir.pwd); warn 'native stderr'")
    directory = File.join(addon_project, 'nested')
    FileUtils.mkdir_p(directory)
    arguments = ['echo', '--help', '--version', '--container-engine', 'docker', '--', '', 'a b',
                 '$(touch sentinel)', '`touch sentinel`', '; touch sentinel', '*.yaml', "line\nbreak"]
    result = addon_cli('addon', 'example', *arguments, directory: directory)
    expect(result.stderr).to eq("native stderr\n")
    expect(result).to be_success
    expect(YAML.safe_load(result.stdout)).to eq('argv' => arguments, 'cwd' => directory)
    expect(File).not_to exist(File.join(directory, 'sentinel'))
  end

  [0, 7, 126, 127, 255].each do |status|
    it "preserves addon exit status #{status}" do
      source.script("exit #{status}")
      result = addon_cli('addon', 'example')
      expect(result.exit_status).to eq(status)
      expect(result.stderr).to be_empty
    end
  end

  it 'preserves inherited user variables while exporting fresh merged configuration and clearing reserved values' do
    source.script(<<~RUBY)
      require 'yaml'
      puts YAML.dump(ENV.to_h.select { |key, _| key.start_with?('EMPEIRA_') || key == 'USER_VALUE' })
    RUBY
    configure_addon(extra: { 'proxy' => { 'nodes' => { 'enabled' => false } },
                             'vm' => { 'console' => { 'root_password' => 'hidden' } } })
    env = { 'USER_VALUE' => 'native', 'EMPEIRA_ADDON_NAME' => 'spoof', 'EMPEIRA_CONFIG_UNSET' => 'stale' }
    data = YAML.safe_load(addon_cli('addon', 'example', environment: env).stdout)
    expect(data).to include('USER_VALUE' => 'native', 'EMPEIRA_ADDON_NAME' => 'example',
                            'EMPEIRA_CONFIG_PROXY_NODES_ENABLED' => 'false')
    expect(data).not_to have_key('EMPEIRA_CONFIG_UNSET')
    expect(data.values).not_to include('hidden', 'spoof', 'stale')
    configure_addon(extra: { 'proxy' => { 'nodes' => { 'enabled' => true } } })
    expect(YAML.safe_load(addon_cli('addon', 'example').stdout)['EMPEIRA_CONFIG_PROXY_NODES_ENABLED']).to eq('true')
  end

  it 'passes stdin directly to the addon' do
    source.script("STDOUT.write(STDIN.read); STDERR.write('stderr')")
    argv = cli_argv
    Open3.popen3({ 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }, *argv,
                 chdir: addon_project) do |input, output, error, process|
      input.write("input with spaces\nsecond line\n")
      input.close
      expect(output.read).to eq("input with spaces\nsecond line\n")
      expect(error.read).to eq('stderr')
      expect(process.value.exitstatus).to eq(0)
    end
  end

  it 'keeps a terminal attached for interactive programs and colors' do
    source.script('puts [$stdin.tty?, $stdout.tty?, $stderr.tty?].join(":"); puts "\e[32mgreen\e[0m"')
    output = +''
    PTY.spawn({ 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }, *cli_argv,
              chdir: addon_project) do |reader, writer, pid|
      writer.close
      begin
        loop { output << reader.readpartial(4096) }
      rescue Errno::EIO, EOFError
        # Linux PTYs report EIO at EOF.
      end
      Process.wait(pid)
    end
    expect(output).to include('true:true:true', "\e[32mgreen\e[0m")
  end

  %w[TERM INT].each do |signal|
    it "hands off process identity and preserves #{signal} termination" do
      source.script('$stdout.sync = true; puts Process.pid; sleep 30')
      Open3.popen3({ 'EMPEIRA_TEST_HOME' => File.join(@directory, 'user-home') }, *cli_argv,
                   chdir: addon_project) do |input, output, _error, process|
        input.close
        pid = Timeout.timeout(15) { Integer(output.gets) }
        expect(pid).to eq(process.pid)
        Process.kill(signal, pid)
        status = Timeout.timeout(5) { process.value }
        expect(status.termsig).to eq(Signal.list.fetch(signal))
      ensure
        Process.kill('KILL', process.pid) if process.alive?
      end
    end
  end

  it 'returns 127 for a missing interpreter and 126 for a nonexecutable entrypoint' do
    source.directory.join('bin/example').write("#!/nonexistent/empeira-fixture-interpreter\n")
    source.commit_changes
    result = addon_cli('addon', 'example')
    expect(result.exit_status).to eq(127)
    expect(result.stderr).to include('Addon example:', 'interpreter was not found')
    source.directory.join('bin/example').chmod(0o644)
    source.commit_changes
    expect(addon_cli('addons', 'update').exit_status).to eq(1)
    configure_addon(ref: source.commit)
    expect(addon_cli('addon', 'example').exit_status).to eq(126)
  end

  it 'reports an unconfigured addon while Core help remains usable' do
    result = addon_cli('addon', 'absent')
    expect(result.exit_status).to eq(1)
    expect(result.stderr).to include('Addon absent: not configured')
    expect(addon_cli('help')).to be_success
  end

  it 'rejects executable text without a shebang instead of falling back to a shell' do
    source.directory.join('bin/example').write("echo unintended-shell\n")
    source.commit_changes
    result = addon_cli('addon', 'example')
    expect(result.exit_status).to eq(126)
    expect(result.stdout).to be_empty
    expect(result.stderr).to include('shebang')
  end

  it 'passes explicit global runtime overrides without interpreting addon flags' do
    source.script("puts ENV.fetch('EMPEIRA_CONFIG_RUNTIME_CONTAINER_ENGINE'); puts ARGV")
    result = addon_cli('--container-engine', 'docker', 'addon', 'example', '--container-engine', 'podman')
    expect(result.stdout.lines.map(&:chomp)).to eq(%w[docker --container-engine podman])
  end

  it 'does not construct runtime services for direct execution and management' do
    application = addon_application
    runner = application.runner
    expect(runner).to receive(:replace).with(anything, arguments: ['echo'],
                                                       environment: a_hash_including('EMPEIRA_ADDON_NAME' => 'example'))
    expect_any_instance_of(Empeira::Runtime::Container).not_to receive(:check_available!)
    expect(Empeira::Infrastructure::Store).not_to receive(:new)
    application.addons.execute('example', ['echo'])
  end

  it 'finishes up infrastructure and reports failed addon synchronization without claiming addon success' do
    app = addon_application
    infrastructure = instance_double(Empeira::Infrastructure::Service)
    allow(app).to receive(:infrastructure).and_return(infrastructure)
    expect(infrastructure).to receive(:up).ordered.and_return(Empeira::Providers::Result.new(resource: nil,
                                                                                             changed: true))
    addons = instance_double(Empeira::Addons::Service)
    allow(app).to receive(:addons).and_return(addons)
    expect(addons).to receive(:synchronize).with(missing_only: true).ordered.and_raise(Empeira::Addons::Error.new(
                                                                                         'example', 'failed'
                                                                                       ))
    allow(Empeira::Application).to receive(:new).and_return(app)
    expect do
      expect { Empeira::CLI::Main.start(['up']) }.to raise_error(Empeira::Addons::Error, /example: failed/)
    end.to output(/Workspace control plane is ready/).to_stdout
  end

  def cli_argv
    [RbConfig.ruby, '-r', File.expand_path('support/isolated_cli_locations.rb', __dir__),
     File.expand_path('../bin/empeira', __dir__), 'addon', 'example']
  end
end
