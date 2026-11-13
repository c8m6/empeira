# frozen_string_literal: true

RSpec.describe Empeira::ControlPlane::StartupFailure do
  let(:resource) { { 'id' => 'owned-proxy', 'state' => 'exited' } }

  def diagnostic
    described_class.new(key: 'proxy', resource: resource, engine: 'podman').message
  end

  it 'identifies unavailable observations without substituting configured limits' do
    expect(diagnostic).to include('exit code unavailable', 'OOM status unavailable', 'memory limit unavailable')
    expect(diagnostic).not_to include('confirmed OOM kill', '512 MiB')
  end

  it 'distinguishes an unlimited native limit from unavailable data' do
    resource['host_config'] = { 'Memory' => 0 }
    expect(diagnostic).to include('memory limit unlimited (runtime reports 0)')
  end

  it 'does not turn string or absent OOM data into confirmation' do
    resource.merge!('oom_killed' => 'true', 'exit_code' => 137, 'host_config' => { 'Memory' => '512' })
    expect(diagnostic).to include('exit code 137', 'OOM status unavailable', 'memory limit unavailable')
    expect(diagnostic).not_to include('confirmed OOM kill')
  end
end

RSpec.describe Empeira::ControlPlane::Health do
  it 'reports an observed proxy OOM during readiness without waiting for the entire timeout' do
    File.write(File.join(@directory, '.empeira.yaml'), YAML.dump('proxy' => { 'nodes' => { 'enabled' => true } }))
    app = Empeira::Application.new(project_path: @directory)
    plan = Empeira::ControlPlane::Plan.new(context: app.context)
    runtime = instance_double(Empeira::Runtime::Podman)
    health = described_class.new(runtime: runtime, plan: plan)
    resources = { 'proxy' => { 'id' => 'proxy-id', 'state' => 'running' }, 'server' => { 'id' => 'server-id' } }
    failure = Empeira::Execution::Result.new(stdout: '', stderr: 'Connection refused', exit_status: 7, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(failure)
    expect(runtime).to receive(:inspect_service).with(an_instance_of(Empeira::Services::Definition),
                                                      expected_id: 'proxy-id').and_return(
                                                        'id' => 'proxy-id', 'state' => 'exited', 'exit_code' => 137,
                                                        'oom_killed' => true,
                                                        'host_config' => { 'Memory' => 134_217_728 }
                                                      )
    expect(health).not_to receive(:sleep)
    expect { health.wait('proxy', resources) }
      .to raise_error(Empeira::ControlPlane::StartupFailure, /confirmed OOM kill/)
  end
end
