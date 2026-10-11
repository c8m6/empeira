# frozen_string_literal: true

require 'pathname'

module Empeira
  module VM
    # Host capability detection belongs to the VM engine, not the public node provider.
    class Qemu < Interface
      EXECUTABLES = { amd64: 'qemu-system-x86_64', arm64: 'qemu-system-aarch64' }.freeze

      def initialize(context:, runner:, executable_path: ENV.fetch('PATH', ''))
        super(name: 'qemu', context: context, runner: runner)
        @executable_path = executable_path
      end

      def executable
        name = EXECUTABLES.fetch(context.platform.architecture)
        find(name) || raise(UnavailableFeature, "#{name} is required for VM nodes; install QEMU")
      end

      def image_tool
        find('qemu-img') || raise(UnavailableFeature, 'qemu-img is required for VM disks; install QEMU')
      end

      def accelerator
        desired = desired_accelerator
        Platform::Kvm.new(platform: context.platform).verify! if desired == 'kvm'
        result = runner.run(executable, arguments: ['-accel', 'help'], timeout: 10)
        return desired if result.success? && result.stdout.lines.any? { |line| line.strip == desired }

        raise UnavailableFeature, "QEMU does not advertise #{desired.upcase} acceleration; no automatic TCG fallback"
      end

      def available?
        executable && image_tool && accelerator
        true
      rescue UnavailableFeature
        false
      end

      private

      def desired_accelerator
        case context.platform.os
        when :linux, :wsl then 'kvm'
        when :macos then 'hvf'
        else raise UnsupportedPlatform, 'QEMU VM nodes require Linux or macOS'
        end
      end

      public

      def required_tools(seeds: true)
        [EXECUTABLES.fetch(context.platform.architecture), 'qemu-img', 'ssh',
         *(seeds ? %w[xorriso ssh-keygen] : [])]
      end

      def preflight!(progress: Progress.new, seeds: true)
        Prerequisites.new(engine: self, platform: context.platform).verify!(progress: progress, seeds: seeds)
      end

      def firmware
        return unless context.platform.architecture == :arm64

        firmware_candidates.find { |path| path.file? && path.readable? } ||
          raise(UnavailableFeature, 'AArch64 UEFI firmware is required with QEMU')
      end

      def firmware_candidates
        root = Pathname(executable).realpath.dirname.parent.join('share')
        [root.join('qemu/edk2-aarch64-code.fd'), root.join('qemu/QEMU_EFI.fd'),
         root.join('qemu-efi-aarch64/QEMU_EFI.fd')]
      end

      def find(name)
        @executable_path.split(File::PATH_SEPARATOR).filter_map do |directory|
          path = Pathname(directory).join(name)
          path.to_s if path.file? && path.executable?
        end.first
      end
    end
  end
end
