# frozen_string_literal: true

require_relative 'support/service_runtime'

RSpec.describe Empeira::Server::EnvironmentCache do
  let(:project) { Pathname(@directory).join('control') }
  let(:runtime) { ServiceRuntime.new }
  let(:app) { Empeira::Application.new(project_path: project) }
  let(:plan) { Empeira::ControlPlane::Plan.new(context: app.context) }
  let(:state) { { 'control_plane' => {} } }
  let(:persist) { spy('persist') }
  let(:server) { { 'id' => 'owned-server' } }
  let(:cache) { described_class.new(plan: plan, runtime: runtime, state: state, persist: persist) }

  before do
    initialize_project(project)
    project.join('manifests').mkpath
    project.join('manifests/site.pp').write("notify { 'first': }\n")
  end

  def requests
    runtime.calls.select { |call| call.first == :exec }.map(&:last)
  end

  it 'invalidates only the selected environment, retaining the cache on an unchanged second run' do
    expect(cache.refresh(server)).to be(true)
    expect(requests.last).to include('--cert', '--key', '--cacert', '--noproxy', '*', 'DELETE')
    expect(requests.last.last).to end_with('/environment-cache?environment=production')
    snapshot = Marshal.load(Marshal.dump(state))
    expect(cache.refresh(server)).to be(false)
    expect(requests.size).to eq(1)
    expect(state).to eq(snapshot)
    expect(persist).to have_received(:call).once
    expect(plan.definitions.fetch('server').options.fetch('environment'))
      .to include('OPENVOXSERVER_ENVIRONMENT_TIMEOUT' => 'unlimited')
  end

  it 'detects uncommitted same-size edits even with a preserved modification time' do
    cache.refresh(server)
    path = project.join('manifests/site.pp')
    stat = path.stat
    path.write("notify { 'other': }\n")
    File.utime(stat.atime, stat.mtime, path)
    expect(cache.refresh(server)).to be(true)
    expect(cache.refresh(server)).to be(false)
    expect(requests.size).to eq(2)
  end

  it 'detects additions, renames and deletions without consulting Git status' do
    cache.refresh(server)
    path = project.join('manifests/untracked.pp')
    path.write("notify { 'new': }\n")
    expect(cache.refresh(server)).to be(true)
    renamed = path.sub_ext('.other.pp')
    path.rename(renamed)
    expect(cache.refresh(server)).to be(true)
    renamed.unlink
    expect(cache.refresh(server)).to be(true)
  end

  it 'ignores Git internals and Empeira state and cache writes' do
    cache.refresh(server)
    project.join('.git/description').write('changed metadata')
    [app.context.locations.state, app.context.locations.cache].each do |root|
      root.mkpath
      root.join('irrelevant').write('state')
    end
    expect(cache.refresh(server)).to be(false)
  end

  it 'invalidates a replaced server and never checkpoints a failed invalidation' do
    cache.refresh(server)
    previous = state.dig('control_plane', 'environment_cache').dup
    failure = Empeira::Execution::Result.new(stdout: '403', stderr: 'synthetic secret', exit_status: 22,
                                             timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(failure)
    expect { cache.refresh('id' => 'replacement') }.to raise_error(Empeira::Error, /invalidation failed/)
    expect(state.dig('control_plane', 'environment_cache')).to eq(previous)
    expect(persist).to have_received(:call).once
    allow(runtime).to receive(:service_exec).and_call_original
    expect(cache.refresh('id' => 'replacement')).to be(true)
  end

  it 'rejects unexpected successful HTTP responses instead of trusting a proxy or login page' do
    response = Empeira::Execution::Result.new(stdout: '200', stderr: '', exit_status: 0, timed_out: false)
    allow(runtime).to receive(:service_exec).and_return(response)
    expect { cache.refresh(server) }.to raise_error(Empeira::Error, /invalidation failed/)
    expect(state.fetch('control_plane')).not_to have_key('environment_cache')
    expect(persist).not_to have_received(:call)
  end

  it 'hashes external Hiera, modules and explicit server data mounts' do
    %w[hiera modules data].each { |name| Pathname(@directory).join(name).mkpath }
    project.join('Puppetfile').write('')
    project.join('.empeira.yaml').write(YAML.dump(
                                          'modules' => { 'path' => '../modules' },
                                          'hiera' => { 'mounts' => [{ 'type' => 'environment', 'source' => '../hiera',
                                                                      'target' => 'data/external' }] },
                                          'server' => { 'mounts' => [{ 'source' => '../data',
                                                                       'target' => '/srv/data' }] }
                                        ))
    cache.refresh(server)
    %w[hiera modules data].each do |name|
      Pathname(@directory).join(name, 'input').write('changed')
      expect(cache.refresh(server)).to be(true)
      expect(cache.refresh(server)).to be(false)
    end
  end

  it 'follows code symlinks and fails closed on cyclic or broken inputs' do
    external = Pathname(@directory).join('external.pp')
    external.write('first')
    File.symlink(external, project.join('manifests/link.pp'))
    cache.refresh(server)
    external.write('second')
    expect(cache.refresh(server)).to be(true)
    external.unlink
    expect { cache.refresh(server) }.to raise_error(Empeira::Error, /Cannot read Puppet code/)
    external.write('restored')
    File.symlink(project, project.join('cycle'))
    expect { cache.refresh(server) }.to raise_error(Empeira::Error, /Cyclic link/)
  end
end
