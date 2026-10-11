# frozen_string_literal: true

RSpec.describe Empeira::Runtime::MountProbe do
  let(:runtime) { instance_double(Empeira::Runtime::Podman) }
  let(:resource) { { 'id' => 'owned-server' } }
  let(:target) { '/etc/puppetlabs/code/environments/production' }
  let(:mount) { "type=bind,src=#{@directory},dst=#{target},readonly" }
  let(:result) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  subject(:probe) { described_class.new(runtime: runtime) }

  before { allow(runtime).to receive(:service_exec).and_return(result) }

  it 'accepts an identical directory listing' do
    expected = Digest::SHA256.hexdigest(Dir.children(@directory).sort.join("\0"))
    allow(runtime).to receive(:service_exec).and_return(result.with(stdout: expected))
    expect { probe.verify(resource, [mount]) }.not_to raise_error
  end

  it 'preserves the native stopped-container failure and mount paths without guessing a sharing problem' do
    native = result.with(exit_status: 255, stderr: 'can only create exec sessions on running containers')
    allow(runtime).to receive(:service_exec).and_return(native)
    expect { probe.verify(resource, [mount]) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include(@directory, target, 'Exit code: 255', native.stderr)
      expect(error.message).not_to include('Configure shared paths')
    end
  end

  it 'distinguishes a successful but different directory listing' do
    allow(runtime).to receive(:service_exec).and_return(result.with(stdout: 'different-listing'))
    expect { probe.verify(resource, [mount]) }
      .to raise_error(Empeira::Error, /directory listing differs.*Source:.*Destination:.*Exit code: 0/m)
  end

  it 'reports unreadable file mounts with bounded sanitized native diagnostics' do
    source = File.join(@directory, 'synthetic-key')
    File.write(source, 'synthetic')
    native = result.with(exit_status: 1, stderr: "Authorization: Bearer synthetic-secret\npermission denied")
    allow(runtime).to receive(:service_exec).and_return(native)
    expect { probe.verify(resource, ["type=bind,src=#{source},dst=/fixture/key,readonly"]) }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include(source, '/fixture/key', 'Exit code: 1', 'permission denied')
        expect(error.message).not_to include('synthetic-secret')
      end
  end
end
