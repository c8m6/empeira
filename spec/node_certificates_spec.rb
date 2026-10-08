# frozen_string_literal: true

RSpec.describe Empeira::Node::Certificates do
  let(:runtime) { instance_double(Empeira::Runtime::Container, copy_from: nil, copy_to: nil) }
  let(:node) { { 'id' => 'node-id' } }
  let(:server) { { 'id' => 'server-id' } }
  let(:certificates) { described_class.new(runtime: runtime, server: server) }
  let(:record) { { 'hostname' => 'test-node' } }
  let(:calls) { [] }

  def result(stdout = '', status = 0)
    Empeira::Execution::Result.new(stdout: stdout, stderr: '', exit_status: status, timed_out: false)
  end

  def ca_entry(state)
    JSON.generate(state => [{ 'name' => 'test-node', 'state' => state }])
  end

  it 'refuses an existing CA identity before generating or signing a node key' do
    expect(runtime).to receive(:service_exec).once.with(server, array_including('list'), timeout: 60)
                                             .and_return(result(ca_entry('signed')))
    expect { certificates.enroll(node, record) { raise 'Unexpected persistence' } }
      .to raise_error(Empeira::Error, /already exists/)
  end

  it 'persists the public key before submitting a CSR so a failed request can be cleaned safely' do
    allow(runtime).to receive(:service_exec) do |resource, arguments, **|
      calls << arguments
      next result('{}') if arguments.include?('list')
      next result('a' * 64) if resource == node && arguments.include?('-e')
      next result('', 1) if arguments.include?('submit_request')

      result
    end
    expect { certificates.enroll(node, record) { calls << :persist } }.to raise_error(Empeira::Error, /request failed/)
    expect(record['certificate_key']).to eq('a' * 64)
    expect(calls.index(:persist)).to be < calls.index { |call| call.is_a?(Array) && call.include?('submit_request') }
    expect(calls).not_to include(array_including('sign'))
  end

  it 'refuses to sign a pending CSR with a different public key' do
    inventories = ['{}', ca_entry('requested')]
    allow(runtime).to receive(:service_exec) do |resource, arguments, **|
      calls << arguments
      next result(inventories.shift) if arguments.include?('list')
      next result(resource == node ? 'a' * 64 : 'b' * 64) if arguments.include?('-e')

      result
    end
    expect { certificates.enroll(node, record) { nil } }.to raise_error(Empeira::Error, /signing refused/)
    expect(calls).not_to include(array_including('sign'))
  end

  it 'refuses to clean a certificate belonging to a different node key' do
    record['certificate_key'] = 'a' * 64
    allow(runtime).to receive(:service_exec) do |_resource, arguments, **|
      calls << arguments
      arguments.include?('list') ? result(ca_entry('signed')) : result('b' * 64)
    end
    expect { certificates.clean(record) }.to raise_error(Empeira::Error, /cleanup refused/)
    expect(calls).not_to include(array_including('clean'))
  end

  it 'cleans only the named certificate after matching its recorded public key' do
    record['certificate_key'] = 'a' * 64
    allow(runtime).to receive(:service_exec) do |_resource, arguments, **|
      calls << arguments
      arguments.include?('list') ? result(ca_entry('signed')) : result('a' * 64)
    end
    certificates.clean(record)
    expect(calls.last).to eq([described_class::CA, 'ca', 'clean', '--certname', 'test-node'])
  end
end
