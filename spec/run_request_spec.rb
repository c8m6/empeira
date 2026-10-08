# frozen_string_literal: true

RSpec.describe Empeira::Node::RunRequest do
  let(:attributes) do
    { hostname: 'host1.example.test', provider: 'vm', os: 'debian', version: '12',
      memory: 1024, cpus: 2 }
  end

  { memory: [0, -1, 1.5, '1024', true], cpus: [0, -2, '2', 1.2],
    provider: ['qemu', :vm, nil], hostname: ['', nil, 'bad..host', '-host'],
    os: ['', ' debian ', 12, false], version: ['', ' 12', 12, true] }.each do |field, values|
    values.each do |value|
      it "rejects #{field}=#{value.inspect} without relying on configuration or CLI validation" do
        expect { described_class.new(**attributes, field => value) }.to raise_error(Empeira::Error, /#{field}/)
      end
    end
  end

  it 'permits explicitly unspecified resource and OS defaults and protects strings' do
    request = described_class.new(**attributes, memory: nil, cpus: nil, os: nil, version: nil)
    expect(request).to be_frozen
    expect(request.hostname).to be_frozen
  end

  it 'selects only request fields from configuration instead of splatting future defaults' do
    config = Empeira::Configuration::Loader.new(project_path: @directory).load
    config['node_defaults']['future_setting'] = 'not a request attribute'
    expect { described_class.from_config(hostname: 'host1', provider: 'vm', config: config) }.not_to raise_error
  end
end
