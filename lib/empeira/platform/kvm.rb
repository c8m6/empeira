# frozen_string_literal: true

require 'etc'
require 'shellwords'

module Empeira
  module Platform
    class Kvm
      DEVICE = '/dev/kvm'

      def initialize(platform:)
        @platform = platform
      end

      def verify!
        version = File.open(DEVICE, File::RDWR) do |device|
          device.ioctl(0xae00)
        rescue SystemCallError => e
          raise UnavailableFeature, "KVM device opens but KVM_GET_API_VERSION ioctl fails (#{e.class})", cause: nil
        end
        return version if version == 12

        raise UnavailableFeature, "KVM returned unsupported API version #{version} (expected 12)"
      rescue Errno::ENOENT
        raise UnavailableFeature, 'KVM is unavailable: /dev/kvm is missing; enable host KVM virtualization', cause: nil
      rescue Errno::EACCES, Errno::EPERM
        raise UnavailableFeature, permission_diagnostic, cause: nil
      rescue SystemCallError => e
        raise UnavailableFeature, "KVM device cannot be opened (#{e.class}); check host device policy", cause: nil
      end

      private

      def permission_diagnostic
        stat = File.stat(DEVICE)
        groups = current_groups
        ["KVM is unavailable: #{DEVICE} is #{access_description}.",
         "Owner: #{user(stat.uid)}:#{group(stat.gid)} (mode #{format('%04o', stat.mode & 0o777)})",
         "Current user: #{user(Process.euid)}", "Current groups: #{group_names(groups)}",
         permission_hint(stat, groups)].join("\n")
      rescue SystemCallError
        'KVM is unavailable: device permissions deny access; inspect /dev/kvm ownership and host device policy'
      end

      def group_names(groups)
        groups.map { |id| group(id) }.join(' ')
      end

      def current_groups
        (Process.groups + [Process.egid]).uniq
      end

      def access_description
        access = []
        access << 'unreadable' unless File.readable?(DEVICE)
        access << 'unwritable' unless File.writable?(DEVICE)
        access << 'denied by device policy' if access.empty?
        access.join(' and ')
      end

      def missing_group?(stat, groups)
        Process.euid != stat.uid && !groups.include?(stat.gid) && stat.mode.allbits?(0o060) &&
          (!File.readable?(DEVICE) || !File.writable?(DEVICE))
      end

      def permission_hint(stat, groups)
        unless missing_group?(stat, groups)
          return 'Device permissions or host security policy deny access; check mode, ACLs and device restrictions.'
        end

        required_group = Shellwords.escape(group(stat.gid))
        hint = "Required group: #{group(stat.gid)}\nSuggested fix: sudo usermod -aG #{required_group} \"$USER\"\n" \
               'Start a new login session for group membership to take effect.'
        hint += "\nOn WSL2 restart the instance/session: wsl.exe --shutdown" if @platform.os == :wsl
        hint
      end

      def user(id)
        Etc.getpwuid(id).name
      rescue ArgumentError
        id.to_s
      end

      def group(id)
        Etc.getgrgid(id).name
      rescue ArgumentError
        id.to_s
      end
    end
  end
end
