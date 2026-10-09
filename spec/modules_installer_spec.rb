# frozen_string_literal: true

require 'empeira/cli/progress'
require 'stringio'

RSpec.describe Empeira::Modules::Installer do
  let(:runtime) { double('runtime', copy_to: nil) }
  let(:state) do
    double('state', sources: Pathname(@directory).join('sources'), cache: Pathname(@directory).join('cache'))
  end
  let(:git) { instance_double(Empeira::Modules::HostGit) }
  let(:installer) { described_class.new(runtime: runtime, image: 'installer-image', git: git) }
  let(:request) { double('request', puppetfile: '', data: { 'overrides' => [] }) }

  before do
    allow(runtime).to receive(:with_update_helper).and_yield('installer')
  end

  it 'preserves actionable module-conflict diagnostics across the container boundary' do
    failure = Empeira::Execution::Result.new(
      stdout: '', stderr: 'Module profile conflicts with control-repository modules', exit_status: 1, timed_out: false
    )
    allow(runtime).to receive(:service_exec).and_return(failure)
    expect(git).not_to receive(:prepare)
    expect { installer.synchronize(request, @directory, state: state) }
      .to raise_error(Empeira::Error, /profile conflicts with control-repository modules/)
  end

  it 'does not expose arbitrary upstream diagnostics containing credentials' do
    failure = Empeira::Execution::Result.new(
      stdout: '', stderr: 'Module profile: https://user:secret@example.org/repo', exit_status: 1, timed_out: false
    )
    allow(runtime).to receive(:service_exec).and_return(failure)
    expect { installer.synchronize(request, @directory, state: state) }
      .to raise_error(Empeira::Error) { |error| expect(error.message).not_to include('secret') }
  end

  [true, false].each do |interactive|
    it "renders only module events and local overrides on success (TTY=#{interactive})" do
      io = StringIO.new
      renderer = Empeira::CLI::ProgressRenderer.new(io: io, interactive: interactive, columns: -> { 80 })
      progress = Empeira::Progress.new(listener: renderer)
      installer = described_class.new(runtime: runtime, image: 'installer-image', git: git, progress: progress)
      request.data['overrides'] = ['hieradata']
      allow(runtime).to receive(:service_exec) do |_, command, on_stdout:, **|
        on_stdout.call("EMPEIRA_MODULE_TOTAL:1\n") if command.last == 'plan'
        on_stdout.call("Cloning into /private/path\nHTTP debug\nEMPEIRA_MOD")
        on_stdout.call("ULE_START:stdlib\nReceiving objects\n")
        on_stdout.call("EMPEIRA_MODULE_DONE:stdlib\n") if command.last == 'sync'
        Empeira::Execution::Result.new(stdout: 'remote: private logs', stderr: 'HTTP verbose', exit_status: 0,
                                       timed_out: false)
      end
      allow(runtime).to receive(:copy_from) do |_, source, destination|
        File.write(destination, JSON.generate('git' => [], 'names' => ['stdlib'])) if source == '/work/git-sources.json'
      end
      allow(git).to receive(:prepare).and_return({})
      names = progress.run('Synchronizing Puppetfile modules...') do
        installer.synchronize(request, @directory, state: state)
      end
      expect(names).to contain_exactly('stdlib', 'hieradata')
      expect(io.string).to include('stdlib', 'hieradata (local override)')
      expect(io.string).not_to include('Cloning', 'HTTP', 'Receiving', 'remote:', 'private')
      if interactive
        expect(io.string).to include("\n\r\e[2Kstdlib (0/1)")
      else
        expect(io.string).to include("[  0%] stdlib (0/1)\n")
        expect(io.string).not_to include("\e")
      end
    end
  end

  it 'reports buffered Forge HTTP failures with the current module' do
    allow(runtime).to receive(:service_exec) do |_, _, on_stdout:, **|
      on_stdout.call("EMPEIRA_MODULE_START:stdlib\n")
      Empeira::Execution::Result.new(stdout: '', stderr: 'the server responded with status 403',
                                     exit_status: 1, timed_out: false)
    end
    expect { installer.synchronize(request, @directory, state: state) }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include('Module: stdlib', 'Operation: Puppetfile plan',
                                         'the server responded with status 403')
      end
  end
end
