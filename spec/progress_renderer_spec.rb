# frozen_string_literal: true

require 'empeira/cli/progress'
require 'stringio'

RSpec.describe Empeira::CLI::ProgressRenderer do
  def event(percent, message, state = :active)
    Empeira::Progress::Event.new(percent: percent, message: message, state: state)
  end

  def frames(output)
    output.scan(/\r\e\[2K([^\n]*)\n\r\e\[2K([^\r\n]*)/)
  end

  # Model only the terminal operations used by the two-line display.
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Model only the terminal operations emitted by the display.
  def visible(output)
    lines = [+'']
    row = 0
    column = 0
    output.scan(/\e\[1A|\e\[2K|./m).each do |token|
      case token
      when "\e[1A" then row -= 1
      when "\e[2K" then lines[row] = +''
      when "\r" then column = 0
      when "\n"
        row += 1
        column = 0
        lines[row] ||= +''
      else
        lines[row][column] = token
        column += 1
      end
    end
    lines.join("\n").rstrip
  end

  [nil, Empeira::Error, Interrupt].each do |failure|
    it "erases only temporary rows and preserves warnings/results after #{failure || 'success'}" do
      io = StringIO.new
      renderer = described_class.new(io: io, interactive: true)
      progress = Empeira::Progress.new(listener: renderer)
      begin
        renderer.during do
          progress.run('Preparing') do
            progress.warning('Warning: preserved')
            progress.stage(40, 'Working')
            raise failure, 'permanent diagnostic' if failure
          end
        end
        io.puts('https://127.0.0.1:12345/')
      rescue Empeira::Error, Interrupt => e
        io.puts("Error: #{e.message}")
      end
      result = failure ? 'Error: permanent diagnostic' : 'https://127.0.0.1:12345/'
      expect(visible(io.string)).to eq("Warning: preserved\n#{result}")
    end
  end

  it 'redraws both rows in place and leaves a fresh line after completion' do
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: true, columns: -> { 30 })
    renderer.call(event(0, 'Preparing'))
    expect(io.string).not_to include("\e[1A")
    renderer.call(event(63, 'Starting PuppetDB...'))
    renderer.call(event(100, 'Completed.', :complete))

    observed = frames(io.string)
    expect(observed.size).to eq(2)
    expect(observed[1]).to eq(['[██████████████--------]  63%', 'Starting PuppetDB...'])
    expect(io.string.scan("\e[1A").size).to eq(2)
    expect(io.string).to end_with("\r\e[2K\e[1A\r\e[2K")
  end

  it 'preserves multiline HTTP diagnostics after ending the progress display' do
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: true)
    progress = Empeira::Progress.new(listener: renderer)
    message = Empeira::Execution::Diagnostics.http(operation: 'Download agent package',
                                                   url: 'https://packages.example.org/agent.deb', status: '404',
                                                   reason: 'Not Found', body: "First explanation\nSecond explanation")
    begin
      renderer.during { progress.run('Downloading') { raise Empeira::Error, message } }
    rescue Empeira::Error => e
      io.puts("Error: #{e.message}")
    end
    expect(visible(io.string)).to eq("Error: #{message}")
    expect(visible(io.string)).not_to include("\e", 'Downloading')
  end

  it 'uses the current terminal width and constrains long Unicode messages without wrapping' do
    io = StringIO.new
    columns = 42
    renderer = described_class.new(io: io, interactive: true, columns: -> { columns })
    widths = [42, 20, 12, 5, 2, 1]
    widths.each do |width|
      columns = width
      renderer.call(event(63, '漢字🚀' * 20))
    end
    observed = frames(io.string)
    expect(observed.size).to eq(widths.size)
    widths.zip(observed).each do |width, (bar, message)|
      expect(bar.length).to be <= width - 1
      expect(message.bytesize).to be <= width - 1
    end
    expect(observed[1].first).to include('63%')
    expect(observed[2].first).to include('63%')
    expect(observed[-2].first).to eq('')
    expect(observed.last).to eq(['', ''])
    renderer.call(event(100, 'Completed.', :complete))
    expect(io.string).to end_with("\r\e[2K\e[1A\r\e[2K")
  end

  it 'redraws heartbeats and stops the heartbeat thread on completion' do
    threads = Thread.list
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: true, columns: -> { 80 }, heartbeat_interval: 0.01)
    progress = Empeira::Progress.new(listener: renderer)
    renderer.during do
      progress.run('Preparing') do
        progress.stage(45, 'Starting PuppetDB...')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        until frames(io.string).any? { |_, message| message.include?('(still working |)') }
          raise 'Heartbeat was not rendered' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.005
        end
      end
    end
    expect(Thread.list - threads).to be_empty
    expect(io.string).not_to include('100%', 'Completed.')
    finished = io.string.dup
    sleep 0.03
    expect(io.string).to eq(finished)
  end

  it 'animates only after inactivity and resets the deadline and frame on real events' do
    now = 0.0
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: true, clock: -> { now }, heartbeat_interval: 10)
    renderer.call(event(40, 'module_name'))
    now = 9.9
    renderer.send(:tick)
    expect(io.string).not_to include('still working')
    now = 10.0
    4.times do
      renderer.send(:tick)
      now += 0.25
    end
    expect(frames(io.string).last(4).map(&:last)).to eq(
      ['module_name (still working |)', 'module_name (still working /)',
       'module_name (still working -)', 'module_name (still working \\)']
    )
    renderer.call(event(45, 'new_event'))
    before = io.string.dup
    now += 0.25
    renderer.send(:tick)
    expect(io.string).to eq(before)
    now += 10
    renderer.send(:tick)
    expect(frames(io.string).last.last).to eq('new_event (still working |)')
    renderer.call(event(45, 'Failed', :failed))
    finished = io.string.dup
    now += 30
    renderer.send(:tick)
    expect(io.string).to eq(finished)
  end

  it 'keeps noninteractive heartbeats infrequent and free of animation' do
    now = 0.0
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: false, clock: -> { now }, heartbeat_interval: 10)
    renderer.call(event(40, 'module_name'))
    81.times do
      renderer.send(:tick)
      now += 0.25
    end
    expect(io.string.lines.size).to eq(3)
    expect(io.string.lines.last).to eq("[ 40%] module_name (still working)\n")
    expect(io.string).not_to include('|', '/', '\\', "\e")
  end

  it 'cleans up both workflow failures and an interruption before a final event' do
    threads = Thread.list
    io = StringIO.new
    renderer = described_class.new(io: io, interactive: true, columns: -> { 40 })
    progress = Empeira::Progress.new(listener: renderer)
    expect do
      renderer.during do
        progress.run('Preparing') do
          progress.stage(45, 'Starting')
          raise Interrupt
        end
      end
    end.to raise_error(Interrupt)
    expect(frames(io.string).map(&:first).last).to include('45%')
    expect(io.string).not_to include('Failed: Starting')
    expect(io.string).to end_with("\r\e[2K\e[1A\r\e[2K")

    io.truncate(0)
    io.rewind
    expect do
      renderer.during do
        renderer.call(event(15, 'Interrupted'))
        raise Interrupt
      end
    end.to raise_error(Interrupt)
    expect(Thread.list - threads).to be_empty
    expect(io.string).to end_with("\r\e[2K\e[1A\r\e[2K")
    expect(io.string.scan("\e[1A").size).to eq(1)
  end

  it 'retains plain lines for redirected output, CI and dumb terminals' do
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    allow($stdout).to receive(:tty?).and_return(false)
    renderer = described_class.new(io: io)
    renderer.call(event(63, "Starting\nPuppetDB"))
    expect(io.string).to eq("[ 63%] Starting PuppetDB\n")
    expect(io.string).not_to include("\e", "\r")

    allow($stdout).to receive(:tty?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TERM').and_return('xterm')
    allow(ENV).to receive(:[]).with('CI').and_return('true')
    described_class.new(io: io).call(event(65, 'CI'))
    expect(io.string).to end_with("[ 65%] CI\n")
    allow(ENV).to receive(:[]).with('CI').and_return(nil)
    allow(ENV).to receive(:[]).with('TERM').and_return('dumb')
    described_class.new(io: io).call(event(70, 'Dumb'))
    expect(io.string).to end_with("[ 70%] Dumb\n")
    expect(io.string).not_to include("\e", "\r")
  end

  it 'reads the TTY size again on every update' do
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    columns = 40
    io.define_singleton_method(:winsize) { [24, columns] }
    allow($stdout).to receive(:tty?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TERM').and_return('xterm')
    allow(ENV).to receive(:[]).with('CI').and_return(nil)
    renderer = described_class.new(io: io)
    renderer.call(event(20, 'Initial width'))
    columns = 18
    renderer.call(event(60, 'After resize'))
    expect(frames(io.string).map { |bar, _| bar.length }).to eq([39, 17])
  end
  [true, false].each do |interactive|
    it "suspends streaming output and resumes on fresh lines (TTY=#{interactive})" do
      io = StringIO.new
      renderer = described_class.new(io: io, interactive: interactive, heartbeat_interval: 0.005)
      progress = Empeira::Progress.new(listener: renderer)
      renderer.during do
        progress.run('Preparing') do
          progress.stage(55, 'Running Puppet')
          progress.streaming do
            text = "Notice: first\nNotice: second"
            text = "\e[32m#{text}\e[0m" if interactive
            io.print(text)
            expect(io.string).to end_with(text)
            before = io.string.dup
            progress.heartbeat
            sleep 0.025
            expect(io.string).to eq(before)
          end
          offset = io.string.size
          progress.stage(85, 'Finalizing')
          expect(io.string[offset..]).not_to include("\e[1A")
        end
      end
      expect(io.string).to include("Notice: first\nNotice: second")
      expect(io.string).not_to include("\e") unless interactive
    end
  end

  [Empeira::Error, Interrupt].each do |failure|
    it "preserves streamed output and a fresh cursor on #{failure}" do
      io = StringIO.new
      renderer = described_class.new(io: io, interactive: true)
      progress = Empeira::Progress.new(listener: renderer)
      expect do
        renderer.during do
          progress.run('Running Puppet') do
            progress.streaming do
              io.print('Notice: preserved')
              raise failure
            end
          end
        end
      end.to raise_error(failure)
      after_stream = io.string.split('Notice: preserved').last
      expect(after_stream).to start_with("\n")
      expect(after_stream).not_to include("\e[1A", '100%')
      expect(after_stream).to end_with("\n")
    end
  end

  [true, false].each do |interactive|
    it "preserves optional-mount warnings outside progress redraws (TTY=#{interactive})" do
      io = StringIO.new
      renderer = described_class.new(io: io, interactive: interactive)
      progress = Empeira::Progress.new(listener: renderer)
      progress.run('Preparing') do
        progress.warning('Warning: optional Hiera mount skipped')
        offset = io.string.size
        progress.stage(30, 'Starting services')
        expect(io.string[offset..]).not_to include("\e[1A")
      end
      expect(io.string).to include("Warning: optional Hiera mount skipped\n")
    end
  end
end
