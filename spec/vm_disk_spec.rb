# frozen_string_literal: true

RSpec.describe Empeira::VM::Disk do
  let(:base) { Pathname(@directory).join('base.qcow2') }
  let(:overlay) { Pathname(@directory).join('vms', 'host1', 'disk.qcow2') }
  let(:engine) { instance_double(Empeira::VM::Qemu, image_tool: 'qemu-img') }
  let(:runner) { instance_double(Empeira::Execution::Runner) }
  let(:disk) { described_class.new(engine: engine, runner: runner, workspace_directory: Pathname(@directory)) }
  let(:base_data) { { 'format' => 'qcow2', 'virtual-size' => 3 * described_class::GIB } }
  let(:overlay_data) do
    { 'format' => 'qcow2', 'virtual-size' => 30 * described_class::GIB,
      'backing-filename' => base.to_s, 'backing-filename-format' => 'qcow2' }
  end

  before do
    File.write(base, 'immutable base')
    allow(runner).to receive(:run) do |_executable, arguments:, **|
      case arguments.first
      when 'create'
        File.write(arguments.last, 'thin overlay')
        result
      when 'resize' then result
      else result(JSON.generate(arguments.last == base.to_s ? base_data : overlay_data))
      end
    end
  end

  def result(stdout = '', status: 0, stderr: '')
    Empeira::Execution::Result.new(stdout: stdout, stderr: stderr, exit_status: status, timed_out: false)
  end

  it 'creates, thin-resizes and verifies a private overlay before publishing it without changing the base' do
    expect(runner).to receive(:run).with('qemu-img', arguments: ['info', '--output=json', base.to_s], timeout: 10)
                                   .ordered.and_return(result(JSON.generate(base_data)))
    expect(runner).to receive(:run).with('qemu-img',
                                         arguments: ['create', '-f', 'qcow2', '-F', 'qcow2', '-b', base.to_s,
                                                     a_string_matching(/disk-.*\.qcow2$/)], timeout: 30)
                                   .ordered do |_, arguments:, **|
      expect(overlay).not_to exist
      File.write(arguments.last, 'thin overlay')
      result
    end
    expect(runner).to receive(:run).with('qemu-img',
                                         arguments: ['resize', '--preallocation=off', '-f', 'qcow2',
                                                     a_string_matching(/disk-.*\.qcow2$/), '30G'], timeout: 30)
                                   .ordered do
      expect(overlay).not_to exist
      result
    end
    expect(disk.create(hostname: 'host1', base: base, size_gib: 30)).to eq(overlay)
    expect(File.stat(overlay).mode & 0o777).to eq(0o600)
    expect(File.read(base)).to eq('immutable base')
    expect(overlay.dirname.children.map { |path| path.basename.to_s }).to eq(['disk.qcow2'])
  end

  it 'rejects a capacity below the actual base before creating an overlay' do
    expect(runner).not_to receive(:run).with(anything, arguments: array_including('create'), timeout: anything)
    expect { disk.create(hostname: 'host1', base: base, size_gib: 2) }
      .to raise_error(Empeira::ConfigurationError, /vm.disk.*smaller.*base image/)
    expect(overlay.dirname).not_to exist
  end

  it 'permits the exact base capacity without shrinking' do
    overlay_data['virtual-size'] = base_data['virtual-size']
    expect(disk.create(hostname: 'host1', base: base, size_gib: 3)).to eq(overlay)
  end

  %w[create resize].each do |operation|
    it "cleans staging and publishes no disk after failed #{operation}" do
      allow(runner).to receive(:run).with('qemu-img', arguments: array_including(operation), timeout: 30)
                                    .and_return(result(status: 1, stderr: 'synthetic capacity failure'))
      expect { disk.create(hostname: 'host1', base: base, size_gib: 30) }
        .to raise_error(Empeira::Error, /Exit code: 1.*synthetic capacity failure/m)
      expect(overlay.dirname.children).to be_empty
      expect(File.read(base)).to eq('immutable base')
    end
  end

  [nil, '3221225472', 0].each do |capacity|
    it "rejects unverified base capacity #{capacity.inspect}" do
      base_data['virtual-size'] = capacity
      expect { disk.create(hostname: 'host1', base: base, size_gib: 30) }
        .to raise_error(Empeira::Error, /base image virtual capacity/)
      expect(overlay).not_to exist
    end
  end

  it 'rejects a chained base' do
    base_data['backing-filename'] = '/foreign.qcow2'
    expect { disk.create(hostname: 'host1', base: base, size_gib: 30) }
      .to raise_error(Empeira::Error, /standalone QCOW2/)
  end

  it 'does not publish an incorrectly resized overlay' do
    overlay_data['virtual-size'] = base_data['virtual-size']
    expect { disk.create(hostname: 'host1', base: base, size_gib: 30) }
      .to raise_error(Empeira::Error, /capacity differs/)
    expect(overlay.dirname.children).to be_empty
  end

  it 'does not publish a foreign backing chain' do
    overlay_data['backing-filename'] = '/foreign.qcow2'
    expect { disk.create(hostname: 'host1', base: base, size_gib: 30) }
      .to raise_error(Empeira::Providers::OwnershipError)
    expect(overlay.dirname.children).to be_empty
  end

  it 'preserves a prepared disk across repeated preparation and verifies it regardless of new sizing' do
    disk.create(hostname: 'host1', base: base, size_gib: 30)
    expect(runner).not_to receive(:run).with(anything, arguments: array_including('resize'), timeout: anything)
    expect { disk.create(hostname: 'host1', base: base, size_gib: 48) }
      .to raise_error(Empeira::Providers::AlreadyExists)
    expect(File.read(overlay)).to eq('thin overlay')
    expect(disk.verify!(hostname: 'host1', base: base)).to eq(overlay)
  end
end
