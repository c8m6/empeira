# frozen_string_literal: true

RSpec.describe Empeira::VM::RootDisk do
  let(:ssh) { instance_double(Empeira::VM::SSH) }
  let(:record) { { 'hostname' => 'vm-host' } }
  let(:gib) { Empeira::VM::Disk::GIB }
  let(:partitions) do
    [{ 'name' => '/dev/vda1', 'type' => 'part', 'size' => gib, 'mountpoint' => '/boot/efi' },
     { 'name' => '/dev/vda5', 'type' => 'part', 'size' => (29 * gib) - (1024**2), 'mountpoint' => '/' }]
  end
  let(:data) do
    { 'blockdevices' => [{ 'name' => '/dev/vda', 'type' => 'disk', 'size' => 30 * gib, 'children' => partitions }] }
  end
  let(:filesystem) { 28 * gib }

  before do
    allow(ssh).to receive(:run).with(record, %w[lsblk --json --bytes --paths --output NAME,TYPE,SIZE,MOUNTPOINT])
                               .and_return(result(JSON.generate(data)))
    allow(ssh).to receive(:run).with(record, ['df', '--block-size=1', '--output=size', '/'])
                               .and_return(result("1B-blocks\n#{filesystem}\n"))
  end

  def result(stdout, status: 0)
    Empeira::Execution::Result.new(stdout: stdout, stderr: 'synthetic disk diagnostic',
                                   exit_status: status, timed_out: false)
  end

  it 'observes the mounted root partition independently of its number and preserves EFI' do
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }.not_to raise_error
    expect(partitions.first['mountpoint']).to eq('/boot/efi')
  end

  it 'accepts decimal byte strings from older lsblk JSON without weakening disk or filesystem checks' do
    data.fetch('blockdevices').first['size'] = (30 * gib).to_s
    partitions.each { |partition| partition['size'] = partition.fetch('size').to_s }
    allow(ssh).to receive(:run).with(record, array_including('lsblk')).and_return(result(JSON.generate(data)))
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }.not_to raise_error
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 48) }
      .to raise_error(Empeira::Error, /partition has not grown/)
  end

  ['30G', '32212254720.0', ' 32212254720', '32212254720junk', '-1', 0, nil, true, 30.0].each do |size|
    it "rejects malformed or nonpositive byte capacity #{size.inspect}" do
      data.fetch('blockdevices').first['size'] = size
      allow(ssh).to receive(:run).with(record, array_including('lsblk')).and_return(result(JSON.generate(data)))
      expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }
        .to raise_error(Empeira::Error, /malformed guest disk metadata/)
    end
  end

  it 'rejects a root partition that was not grown' do
    partitions.last['size'] = 2 * gib
    allow(ssh).to receive(:run).with(record, array_including('lsblk')).and_return(result(JSON.generate(data)))
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }
      .to raise_error(Empeira::Error, /partition has not grown.*vda5.*unpartitioned=/)
  end

  context 'when only the partition grew' do
    let(:filesystem) { 2 * gib }

    it 'rejects the original filesystem capacity' do
      expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }
        .to raise_error(Empeira::Error, /filesystem has not grown.*filesystem=/)
    end
  end

  it 'rejects a different disk capacity' do
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 48) }
      .to raise_error(Empeira::Error, /partition has not grown.*expected=/)
  end

  it 'fails with native diagnostics when inspection is unsuccessful' do
    allow(ssh).to receive(:run).with(record, array_including('lsblk')).and_return(result('', status: 1))
    expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }
      .to raise_error(Empeira::Error, /root disk growth.*Exit code: 1.*synthetic disk diagnostic/m)
  end

  [[], nil, {}, [{ 'mountpoint' => '/' }]].each do |devices|
    it "fails closed for unrecognizable root layout #{devices.inspect}" do
      data['blockdevices'] = devices
      allow(ssh).to receive(:run).with(record, array_including('lsblk')).and_return(result(JSON.generate(data)))
      expect { described_class.new(ssh: ssh).verify!(record, size_gib: 30) }.to raise_error(Empeira::Error)
    end
  end
end
