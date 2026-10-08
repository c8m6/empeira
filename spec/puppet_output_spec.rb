# frozen_string_literal: true

require 'pty'

RSpec.describe Empeira::Node::PuppetCommand do
  before do
    allow(ENV).to receive(:[]).and_call_original
    %w[CI NO_COLOR].each { |key| allow(ENV).to receive(:[]).with(key).and_return(nil) }
    allow(ENV).to receive(:[]).with('TERM').and_return('xterm-256color')
    allow($stdout).to receive(:tty?).and_return(true)
    allow($stderr).to receive(:tty?).and_return(true)
  end

  it 'requests ANSI on an interactive terminal and preserves it through the process runner' do
    expect(described_class.arguments.last(2)).to eq(%w[--color ansi])
    PTY.open do |reader, writer|
      result = Empeira::Execution::Runner.new.stream(
        RbConfig.ruby, arguments: ['-e', '$stdout.write "\e[32mNotice: catalog\e[0m"'],
                       output: writer, error: writer
      )
      expect(result).to be_success
      expect(reader.readpartial(1024)).to eq("\e[32mNotice: catalog\e[0m")
    end
  end

  %i[stdout stderr].each do |stream|
    it "disables Puppet color when #{stream} is redirected" do
      allow(stream == :stdout ? $stdout : $stderr).to receive(:tty?).and_return(false)
      expect(described_class.arguments.last(2)).to eq(%w[--color false])
    end
  end

  { 'CI' => 'true', 'TERM' => 'dumb', 'NO_COLOR' => '1' }.each do |key, value|
    it "disables Puppet color for #{key}=#{value}, even with a TTY" do
      allow(ENV).to receive(:[]).with(key).and_return(value)
      expect(described_class.arguments.last(2)).to eq(%w[--color false])
    end
  end
end
