# frozen_string_literal: true

RSpec.describe Empeira::Runtime::MountProbe, :files_only do
  let(:runtime) { instance_double(Empeira::Runtime::Podman) }
  let(:resource) { { 'id' => 'owned-server' } }
  let(:source) { File.join(@directory, 'source') }
  let(:target) { File.join(@directory, 'guest') }
  let(:mount) { "type=bind,src=#{source},dst=#{target},readonly" }
  let(:result) { Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false) }
  subject(:probe) { described_class.new(runtime: runtime) }

  before do
    [source, target].each do |path|
      FileUtils.mkdir_p(path)
      File.write(File.join(path, 'data'), 'synthetic')
    end
    allow(runtime).to receive(:service_exec) do |_resource, arguments|
      Empeira::Execution::Runner.new.run(RbConfig.ruby, arguments: arguments.drop(1))
    end
  end

  it 'checks files and identical directory listings in one guest invocation' do
    file = "type=bind,src=#{source}/data,dst=#{target}/data,readonly"
    expect(runtime).to receive(:service_exec).once do |_resource, arguments|
      Empeira::Execution::Runner.new.run(RbConfig.ruby, arguments: arguments.drop(1))
    end
    expect { probe.verify(resource, [mount, file, mount]) }.not_to raise_error
  end

  it 'preserves the native stopped-container failure and mount paths without guessing a sharing problem' do
    native = result.with(exit_status: 255, stderr: 'can only create exec sessions on running containers')
    allow(runtime).to receive(:service_exec).and_return(native)
    expect { probe.verify(resource, [mount]) }.to raise_error(Empeira::Error) do |error|
      expect(error.message).to include(source, target, 'Exit code: 255', native.stderr)
      expect(error.message).not_to include('Configure shared paths')
    end
  end

  it 'rejects different directory listings through the actual guest probe' do
    File.write(File.join(target, 'unexpected'), '')
    expect { probe.verify(resource, [mount]) }
      .to raise_error(Empeira::Error, /Source:.*Destination:.*directory listing differs/m)
  end

  it 'reports unreadable file mounts with bounded sanitized native diagnostics' do
    native = result.with(exit_status: 1, stderr: "Authorization: Bearer synthetic-secret\npermission denied")
    allow(runtime).to receive(:service_exec).and_return(native)
    expect { probe.verify(resource, ["type=bind,src=#{source}/data,dst=/fixture/key,readonly"]) }
      .to raise_error(Empeira::Error) do |error|
        expect(error.message).to include(source, '/fixture/key', 'Exit code: 1', 'permission denied')
        expect(error.message).not_to include('synthetic-secret')
      end
  end
end
