# frozen_string_literal: true

RSpec.describe 'Personal SSH application handoff' do
  let(:preferences) do
    { 'user' => 'global', 'identity' => '~/global/key',
      'rules' => [{ 'hosts' => ['web-*'], 'user' => 'web-user' },
                  { 'hosts' => ['*.example.net'], 'identity' => '~/host/key' }] }
  end
  let(:locations) { Empeira::Platform::Locations.new(home: File.join(@directory, 'user-home'), environment: {}) }
  let(:container) { instance_double(Empeira::Node::Container) }
  let(:vm) { instance_double(Empeira::Node::VM) }
  let(:registry) do
    Empeira::Providers::Registry.new('container' => ->(**) { container }, 'vm' => ->(**) { vm })
  end
  let(:app) do
    locations.user_configuration.write(YAML.dump('ssh' => preferences))
    Empeira::Application.new(project_path: @directory, locations: locations, factories: { providers: registry })
  end
  let(:state) { { 'nodes' => { 'web-a.example.net' => { 'provider' => 'vm' } } } }

  before do
    store = instance_double(Empeira::Infrastructure::Store, load: state)
    allow(Empeira::Infrastructure::Store).to receive(:new).and_return(store)
  end

  it 'passes resolved preferences to the recorded VM provider' do
    expect(vm).to receive(:ssh).with(name: 'WEB-A.EXAMPLE.NET', user: 'web-user', identity: '~/host/key', port: nil)
    app.nodes.ssh(name: 'WEB-A.EXAMPLE.NET')
  end

  it 'passes global preferences to the container provider' do
    expect(container).to receive(:ssh).with(name: 'db', user: 'global', identity: '~/global/key', port: nil)
    app.nodes.ssh(name: 'db')
  end

  [{ user: 'cli-user' }, { identity: '/cli/key' }, { user: 'cli-user', identity: '/cli/key' }].each do |overrides|
    it "preserves independent CLI #{overrides.keys.join('/')} precedence through Application" do
      values = { user: 'web-user', identity: '~/host/key', port: nil }.merge(overrides)
      expect(vm).to receive(:ssh).with(name: 'web-a.example.net', **values)
      app.nodes.ssh(name: 'web-a.example.net', **overrides)
    end
  end

  %i[start stop shell puppet logs inspect_resource].each do |operation|
    it "leaves #{operation} independent of personal login settings" do
      expect(vm).to receive(operation).with(name: 'web-a.example.net')
      app.nodes.public_send(operation, name: 'web-a.example.net')
    end
  end

  it 'passes no personal configuration into run requests or provider factories' do
    request = Empeira::Node::RunRequest.from_config(hostname: 'new-vm', provider: 'vm',
                                                    config: app.context.configuration)
    expect(vm).to receive(:run).with(request)
    app.nodes.run(request)
    expect(request.members).not_to include(:ssh, :ssh_preferences, :user, :identity)
    expect(app.context.configuration).not_to have_key('ssh')
  end
end
