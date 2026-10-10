# frozen_string_literal: true

RSpec.describe Empeira::VM::SystemSSH do
  let(:app) { Empeira::Application.new(project_path: @directory) }
  let(:runtime) { instance_double(Empeira::Runtime::Podman) }
  let(:qemu) { instance_double(Empeira::VM::QemuRuntime, running?: true) }
  let(:peer) { instance_double(Empeira::Network::Peer::LinuxPodman) }
  let(:client) { instance_double(Empeira::Node::UserSSH) }
  let(:record) { { 'hostname' => 'node.example.test', 'ssh_port' => 32_123 } }
  subject(:system) { described_class.new(context: app.context, runner: app.runner, runtime: runtime, qemu: qemu) }

  before do
    allow(Empeira::Network::Peer::Backend).to receive(:build).and_return(peer)
    allow(Empeira::Node::UserSSH).to receive(:new).with(hash_including(proxy_command: ['owned-peer-tunnel']))
                                                  .and_return(client)
    expect(Empeira::VM::SSH).not_to receive(:new)
  end

  [22, 2222].each do |port|
    it "connects directly to system port #{port} without a management layout or healthy management service" do
      expect(peer).to receive(:system_ssh_command).with(record, port: port).and_return(['owned-peer-tunnel'])
      expect(client).to receive(:session).with(record.merge('ssh_port' => port),
                                               user: 'admin', identity: '/personal/key')
      system.session(record, user: 'admin', identity: '/personal/key', port: port == 22 ? nil : port)
      expect(record['ssh_port']).to eq(32_123)
      expect(record).not_to have_key('ssh_layout')
    end
  end

  it 'rejects a missing or foreign VM before connecting to the peer network' do
    allow(qemu).to receive(:running?).and_return(false)
    expect(peer).not_to receive(:system_ssh_command)
    expect { system.session(record) }.to raise_error(Empeira::Error, /Recorded VM is not running/)
  end

  it 'returns the native system SSH failure without attempting repair or fallback' do
    expect(peer).to receive(:system_ssh_command).with(record, port: 22).and_return(['owned-peer-tunnel'])
    result = Empeira::Execution::Result.new(stdout: '', stderr: 'Permission denied (publickey)',
                                            exit_status: 255, timed_out: false)
    expect(client).to receive(:session).and_return(result)
    expect(system.session(record)).to eq(result)
  end
end
