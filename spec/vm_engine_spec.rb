# frozen_string_literal: true

require 'json'

RSpec.describe 'QEMU VM prerequisites and overlays' do
  def context(os:, architecture:)
    Struct.new(:platform).new(Struct.new(:os, :architecture).new(os, architecture))
  end

  def fake_executables
    %w[qemu-system-x86_64 qemu-system-aarch64 qemu-img].each do |name|
      path = File.join(@directory, name)
      File.write(path, '')
      File.chmod(0o755, path)
    end
  end

  it 'selects the native executable and HVF on macOS' do
    fake_executables
    runner = instance_double(Empeira::Execution::Runner)
    allow(runner).to receive(:run).with(File.join(@directory, 'qemu-system-aarch64'),
                                        arguments: ['-accel', 'help'], timeout: 10).and_return(
                                          Empeira::Execution::Result.new(stdout: "tcg\nhvf\n", stderr: '',
                                                                         exit_status: 0, timed_out: false)
                                        )
    engine = Empeira::VM::Qemu.new(context: context(os: :macos, architecture: :arm64), runner: runner,
                                   executable_path: @directory)
    expect(engine.executable).to end_with('qemu-system-aarch64')
    expect(engine.accelerator).to eq('hvf')
  end

  it 'does not fall back to TCG when HVF is unavailable' do
    fake_executables
    runner = instance_double(Empeira::Execution::Runner)
    allow(runner).to receive(:run).and_return(
      Empeira::Execution::Result.new(stdout: "tcg\n", stderr: '', exit_status: 0, timed_out: false)
    )
    engine = Empeira::VM::Qemu.new(context: context(os: :macos, architecture: :amd64), runner: runner,
                                   executable_path: @directory)
    expect { engine.accelerator }.to raise_error(Empeira::UnavailableFeature, /no automatic TCG/)
  end

  it 'requires actual KVM device access on Linux and WSL2' do
    fake_executables
    engine = Empeira::VM::Qemu.new(context: context(os: :wsl, architecture: :amd64),
                                   runner: instance_double(Empeira::Execution::Runner), executable_path: @directory)
    allow(File).to receive(:open).with('/dev/kvm', File::RDWR).and_raise(Errno::EACCES)
    expect { engine.accelerator }.to raise_error(Empeira::UnavailableFeature, /KVM is unavailable/)
  end

  it 'rejects QEMU without KVM even when the device API works' do
    fake_executables
    allow(Empeira::Platform::Kvm).to receive(:new).and_return(instance_double(Empeira::Platform::Kvm, verify!: 12))
    runner = instance_double(Empeira::Execution::Runner)
    allow(runner).to receive(:run).and_return(
      Empeira::Execution::Result.new(stdout: "tcg\n", stderr: '', exit_status: 0, timed_out: false)
    )
    engine = Empeira::VM::Qemu.new(context: context(os: :linux, architecture: :amd64),
                                   runner: runner, executable_path: @directory)
    expect { engine.accelerator }.to raise_error(Empeira::UnavailableFeature, /does not advertise KVM/)
  end

  it 'creates a QCOW2 overlay and verifies its exact backing file before removal' do
    base = Pathname(@directory).join('base.qcow2')
    File.write(base, 'base')
    engine = instance_double(Empeira::VM::Qemu, image_tool: '/usr/local/bin/qemu-img')
    runner = instance_double(Empeira::Execution::Runner)
    allow(runner).to receive(:run) do |_executable, arguments:, **_options|
      if arguments.first == 'create'
        File.write(arguments[-1], 'overlay')
        Empeira::Execution::Result.new(stdout: '', stderr: '', exit_status: 0, timed_out: false)
      else
        metadata = if arguments.last == base.to_s
                     { 'format' => 'qcow2' }
                   else
                     { 'format' => 'qcow2', 'backing-filename' => base.to_s,
                       'backing-filename-format' => 'qcow2' }
                   end
        Empeira::Execution::Result.new(stdout: JSON.generate(metadata), stderr: '', exit_status: 0, timed_out: false)
      end
    end
    disk = Empeira::VM::Disk.new(engine: engine, runner: runner, workspace_directory: Pathname(@directory))
    overlay = disk.create(hostname: 'host1', base: base)
    expect(overlay).to exist
    expect(disk.verify!(hostname: 'host1', base: base)).to eq(overlay)
    expect { disk.verify!(hostname: 'host1', base: Pathname(@directory).join('different.qcow2')) }
      .to raise_error(Empeira::Providers::OwnershipError)
    disk.remove(hostname: 'host1', base: base)
    expect(overlay).not_to exist
    expect(base).to exist
  end
end
