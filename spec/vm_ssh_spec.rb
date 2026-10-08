# frozen_string_literal: true

RSpec.describe Empeira::VM::SSH do
  let(:success) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:transport) { described_class.new(context: nil, runner: runner, cloud_init: nil) }
  let(:record) { {} }

  before do
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
      expect { transport.copy_to(record, 'private-source', '/var/tmp/private') }
        .to raise_error(Empeira::Error, /Cannot copy/)
      expect(transport).to have_received(:run).with(record, ['rm', '-f', '--', path])
      expect(transport).not_to have_received(:run).with(record, array_including('install'))
    end
  end

  it 'fails closed when upload succeeds but staging removal fails' do
    allow(runner).to receive(:run).and_return(success)
    allow(transport).to receive(:run).with(record, array_including('rm')).and_return(success.with(exit_status: 1))
    expect { transport.copy_to(record, 'private-source', '/var/tmp/private', mode: '0600') }
      .to raise_error(Empeira::Error, /staging cleanup/)
    expect(transport).to have_received(:run).with(record, array_including('install', '-m', '0600'))
  end

  it 'attempts staging removal even if the transfer raises an exception' do
    allow(runner).to receive(:run).and_raise(Empeira::Error, 'transfer interrupted')
    expect do
      transport.copy_to(record, 'private-source', '/var/tmp/private')
    end.to raise_error(Empeira::Error, /interrupted/)
    expect(transport).to have_received(:run).with(record, array_including('rm', '-f', '--'))
  end
end
