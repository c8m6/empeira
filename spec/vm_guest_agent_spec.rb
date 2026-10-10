# frozen_string_literal: true

RSpec.describe 'Guest VirtIO execution adapter' do
  it 'preserves complete output and native exits, cancels processes and publishes verified binary uploads' do
    runner = Empeira::Execution::Runner.new
    probe = File.expand_path('support/guest_agent_probe.py', __dir__)
    agent = Empeira::VM::Management.resource('guest_agent.py')
    result = runner.run('python3', arguments: [probe, agent.to_s], timeout: 20)
    expect(result).to be_success, result.stderr
    expect(result.stdout).to include('large stdout/stderr', 'closed-pipe timeout', 'binary upload and cleanup passed')
  end
end
