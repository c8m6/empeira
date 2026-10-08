# frozen_string_literal: true

RSpec.describe Empeira::Platform::Kvm do
  let(:platform) { Struct.new(:os).new(:linux) }
  let(:probe) { described_class.new(platform: platform) }
  let(:device) { instance_double(File) }

  it 'reports a missing device' do
    allow(File).to receive(:open).with('/dev/kvm', File::RDWR).and_raise(Errno::ENOENT)
    expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature, /missing/)
  end

  it 'accepts a usable API regardless of group membership or mode bits' do
    allow(File).to receive(:open).with('/dev/kvm', File::RDWR).and_yield(device)
    allow(device).to receive(:ioctl).with(0xae00).and_return(12)
    expect(File).not_to receive(:stat)
    expect(probe.verify!).to eq(12)
  end

  it 'distinguishes failed ioctl from denied open and unsupported API' do
    allow(File).to receive(:open).with('/dev/kvm', File::RDWR).and_yield(device)
    allow(device).to receive(:ioctl).and_raise(Errno::EPERM)
    expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature, /opens but.*ioctl fails/)
    allow(device).to receive(:ioctl).and_return(7)
    expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature, /unsupported API version 7/)
  end

  context 'with denied device access' do
    before do
      allow(File).to receive(:open).with('/dev/kvm', File::RDWR).and_raise(Errno::EACCES)
      allow(File).to receive(:stat).with('/dev/kvm').and_return(Struct.new(:uid, :gid, :mode).new(0, 101, 0o660))
      allow(Process).to receive_messages(euid: 1000, egid: 1000, groups: [1000])
      allow(Etc).to receive(:getpwuid) { |id| Struct.new(:name).new(id.zero? ? 'root' : 'tester') }
      allow(Etc).to receive(:getgrgid) { |id| Struct.new(:name).new(id == 101 ? 'kvm' : 'tester') }
      allow(File).to receive(:readable?).with('/dev/kvm').and_return(false)
      allow(File).to receive(:writable?).with('/dev/kvm').and_return(false)
    end

    it 'reports the actual owner, missing group and login hint on Linux' do
      expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature) { |error|
        expect(error.message).to include('unreadable and unwritable', 'root:kvm', 'Current user: tester',
                                         'Current groups: tester', 'sudo usermod -aG kvm "$USER"')
        expect(error.message).not_to include('wsl.exe')
      }
    end

    it 'adds a WSL restart hint only on WSL' do
      platform.os = :wsl
      expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature, /wsl.exe --shutdown/)
    end

    it 'distinguishes unreadable from unwritable and avoids an incorrect group diagnosis' do
      allow(Process).to receive(:groups).and_return([1000, 101])
      allow(File).to receive(:readable?).with('/dev/kvm').and_return(true)
      expect { probe.verify! }.to raise_error(Empeira::UnavailableFeature) { |error|
        expect(error.message).to include('unwritable', 'Device permissions or host security policy')
        expect(error.message).not_to include('unreadable', 'Required group')
      }
    end
  end
end

RSpec.describe Empeira::VM::Prerequisites do
  let(:platform) { Empeira::Platform::Facts.new(host_os: 'linux', host_cpu: 'x86_64', environment: {}, kernel_release: '') }
  let(:engine) do
    instance_double(Empeira::VM::Qemu, required_tools: %w[qemu-system-x86_64 qemu-img xorriso ssh],
                                       accelerator: 'kvm', firmware: nil)
  end
  let(:collector) { described_class.new(engine: engine, platform: platform) }

  before { allow(engine).to receive(:find).and_return('/synthetic/tool') }

  it 'returns the usable accelerator when all prerequisites are present' do
    expect(collector.verify!).to eq('kvm')
  end

  it 'reports all missing tools together with accelerator failures' do
    allow(engine).to receive(:find).with('xorriso').and_return(nil)
    allow(engine).to receive(:find).with('ssh').and_return(nil)
    allow(engine).to receive(:accelerator).and_raise(Empeira::UnavailableFeature, 'KVM missing')
    expect { collector.verify! }.to raise_error(Empeira::UnavailableFeature) { |error|
      expect(error.message).to match(/xorriso\s+missing/)
      expect(error.message).to match(/ssh\s+missing/)
      expect(error.message).to include('KVM missing', 'qemu-img')
    }
  end

  it 'reports one missing tool with Ubuntu and macOS installation hints' do
    allow(engine).to receive(:find).with('xorriso').and_return(nil)
    allow(File).to receive(:read).with('/etc/os-release').and_return("ID=ubuntu\n")
    expect { collector.verify! }.to raise_error(Empeira::UnavailableFeature, /sudo apt install qemu-system-x86/)
    mac = Empeira::Platform::Facts.new(host_os: 'darwin', host_cpu: 'arm64')
    expect(mac.vm_install_hint).to include('brew install qemu xorriso')
  end
end
