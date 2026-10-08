# frozen_string_literal: true

require 'empeira/cli/progress'
require 'stringio'

RSpec.describe Empeira::Modules::Events do
  let(:events) { [] }
  let(:progress) { Empeira::Progress.new(listener: ->(event) { events << event }) }
  let(:protocol) { described_class.new(progress: progress) }

  [[10, 1, 10], [20, 4, 20], [28, 14, 50], [200, 199, 99]].each do |total, done, percent|
    it "reports #{done}/#{total} as #{percent}% only after successful module completion" do
      progress.run('Reading Puppetfile...') do
        protocol.observe("EMPEIRA_MODULE_TOTAL:#{total}\n")
        done.times do |index|
          protocol.observe("ordinary r10k logs\nEMPEIRA_MODULE_START:module_#{index}\n")
          expect(events.last.percent).to eq([(100.0 * index / total).round, 99].min)
          protocol.observe("EMPEIRA_MODULE_DONE:module_#{index}\n")
        end
        expect(events.last.percent).to eq(percent)
        expect(events.last.message).to eq("module_#{done - 1} (#{done}/#{total})")
      end
    end
  end

  it 'does not count a failed module or manufacture successful completion' do
    expect do
      progress.run('Reading Puppetfile...') do
        protocol.observe("EMPEIRA_MODULE_TOTAL:10\nEMPEIRA_MODULE_START:profile\n")
        protocol.observe("EMPEIRA_MODULE_DONE:profile\nEMPEIRA_MODULE_START:broken\n")
        raise Empeira::Error, 'synthetic module error'
      end
    end.to raise_error(Empeira::Error)
    expect(events.last).to have_attributes(percent: 10, state: :failed, message: 'Failed: broken (1/10)')
    expect(events.map(&:percent)).not_to include(100)
  end

  it 'completes zero effective modules without division by zero' do
    progress.run('Reading Puppetfile...') do
      protocol.observe("EMPEIRA_MODULE_TOTAL:0\n")
      protocol.finish!
      expect(events.last).to have_attributes(percent: 100, message: 'Puppetfile modules (0/0)')
    end
  end

  it 'handles split records and refuses duplicate or incomplete completion' do
    protocol.observe('EMPEIRA_MODULE_TOT')
    protocol.observe("AL:1\nEMPEIRA_MODULE_START:profile\n")
    expect { protocol.finish! }.to raise_error(Empeira::Error, /Incomplete/)
    protocol.observe("EMPEIRA_MODULE_DONE:profile\n")
    protocol.finish!
    expect { protocol.observe("EMPEIRA_MODULE_DONE:profile\n") }.to raise_error(Empeira::Error, /completion/)
  end

  it 'keeps the global spinner active while a module is slow' do
    now = 0.0
    io = StringIO.new
    renderer = Empeira::CLI::ProgressRenderer.new(io: io, interactive: true, clock: -> { now })
    progress = Empeira::Progress.new(listener: renderer)
    protocol = described_class.new(progress: progress)
    progress.run('Reading Puppetfile...') do
      protocol.observe("EMPEIRA_MODULE_TOTAL:10\nEMPEIRA_MODULE_START:profile\n")
      now = 10.0
      renderer.send(:tick)
      expect(io.string).to include('profile (0/10) (still working |)')
      protocol.observe("EMPEIRA_MODULE_DONE:profile\n")
      expect(io.string).to include('profile (1/10)')
    end
  end
end
