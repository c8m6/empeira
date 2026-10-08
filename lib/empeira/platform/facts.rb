# frozen_string_literal: true

require 'rbconfig'

module Empeira
  module Platform
    class Facts
      attr_reader :os, :architecture

      def initialize(host_os: RbConfig::CONFIG.fetch('host_os'), host_cpu: RbConfig::CONFIG.fetch('host_cpu'),
                     environment: ENV, kernel_release: nil)
        @os = detect_os(host_os, environment, kernel_release)
        @architecture = normalize_architecture(host_cpu)
        freeze
      end

      def process_groups?
        true
      end

      def vm_install_hint
        return 'Install QEMU, xorriso and OpenSSH, for example: brew install qemu xorriso' if os == :macos

        release = File.read('/etc/os-release')
        if release.match?(/^(?:ID|ID_LIKE)=.*(?:ubuntu|debian)/)
          package = architecture == :arm64 ? 'qemu-system-arm qemu-efi-aarch64' : 'qemu-system-x86'
          return "Install missing dependencies: sudo apt install #{package} qemu-utils xorriso openssh-client"
        end
        'Install QEMU system tools, qemu-img, xorriso and OpenSSH using your host distribution package manager.'
      rescue SystemCallError
        'Install QEMU system tools, qemu-img, xorriso and OpenSSH using your host distribution package manager.'
      end

      private

      def detect_os(host_os, environment, kernel_release)
        case host_os.downcase
        when /linux/ then wsl?(environment, kernel_release) ? :wsl : :linux
        when /darwin/ then :macos
        else raise UnsupportedPlatform, 'Unsupported operating system (expected Linux, macOS, or WSL2)'
        end
      end

      def wsl?(environment, kernel_release)
        return true if %w[WSL_INTEROP WSL_DISTRO_NAME].any? { |key| !environment[key].to_s.empty? }

        release = kernel_release || read_kernel_release
        release.match?(/microsoft|wsl/i)
      end

      def read_kernel_release
        File.read('/proc/sys/kernel/osrelease')
      rescue SystemCallError
        ''
      end

      def normalize_architecture(cpu)
        case cpu.downcase
        when /\A(?:x86_64|amd64|x64)(?:\W|\z)/ then :amd64
        when /\A(?:aarch64|arm64)(?:\W|\z)/ then :arm64
        else raise UnsupportedPlatform, 'Unsupported architecture (expected amd64 or arm64)'
        end
      end
    end
  end
end
