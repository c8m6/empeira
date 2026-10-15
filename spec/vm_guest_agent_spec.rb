# frozen_string_literal: true

RSpec.describe 'Guest VirtIO execution adapter' do
  it 'preserves complete output and native exits, cancels processes and publishes verified binary uploads' do
    unless RbConfig::CONFIG.fetch('host_os').include?('linux')
      skip 'Linux guest probe requires epoll and waitid; required on every Ubuntu Ruby matrix job'
    end

    runner = Empeira::Execution::Runner.new
    probe = File.expand_path('support/guest_agent_probe.py', __dir__)
    agent = Empeira::VM::Management.resource('guest_agent.py')
    result = runner.run('python3', arguments: [probe, agent.to_s], timeout: 40)
    expect(result).to be_success, result.stderr
    expect(result.stdout).to include('large stdout/stderr', 'closed-pipe timeout', 'binary upload and cleanup passed')
    expect(result.stdout).to include('PTY, resize, ANSI, Ctrl+C/D/Z', 'background cleanup passed')
  end
end
