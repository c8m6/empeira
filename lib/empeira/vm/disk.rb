# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tempfile'

module Empeira
  module VM
    # One writable QCOW2 overlay per node; the shared base remains read-only.
    class Disk
      GIB = 1024**3

      def initialize(engine:, runner:, workspace_directory:)
        @engine = engine
        @runner = runner
        @workspace_directory = workspace_directory
      end

      def create(hostname:, base:, size_gib:)
        require_base!(base)
        verify_capacity!(base, size_gib)
        directory = node_directory(hostname)
        FileUtils.mkdir_p(directory, mode: 0o700)
        overlay = directory.join('disk.qcow2')
        raise Providers::AlreadyExists, 'VM overlay already exists' if overlay.exist? || overlay.symlink?

        Tempfile.create(['disk-', '.qcow2'], directory) do |temporary|
          staging = Pathname(temporary.path)
          prepare_overlay!(base, staging, size_gib)
          File.link(staging, overlay)
        end
        overlay
      end

      def verify!(hostname:, base:)
        overlay = node_directory(hostname).join('disk.qcow2')
        raise Error, 'VM overlay is missing or unsafe' unless overlay.file? && !overlay.symlink?

        verify_backing!(overlay_metadata(overlay), base)
        overlay
      end

      def remove(hostname:, base:)
        overlay = verify!(hostname: hostname, base: base)
        File.unlink(overlay)
        overlay
      end

      private

      def prepare_overlay!(base, overlay, size_gib)
        create_overlay!(base, overlay)
        resize_overlay!(overlay, size_gib)
        data = overlay_metadata(overlay)
        verify_backing!(data, base)
        raise Error, 'VM overlay capacity differs from vm.disk' unless data['virtual-size'] == size_gib * GIB
      end

      def verify_backing!(data, base)
        return if data['format'] == 'qcow2' && data['backing-filename'] == base.to_s &&
                  data['backing-filename-format'] == 'qcow2'

        raise Providers::OwnershipError, 'VM overlay backing image differs from recorded base'
      end

      def verify_capacity!(base, size_gib)
        raise ConfigurationError, 'vm.disk must be an integer from 1 to 2048 GiB' unless
          size_gib.is_a?(Integer) && (1..2048).cover?(size_gib)

        capacity = verify_base!(base).fetch('virtual-size', nil)
        raise Error, 'VM base image virtual capacity is missing or invalid' unless
          capacity.is_a?(Integer) && capacity.positive?
        return if size_gib * GIB >= capacity

        raise ConfigurationError, "vm.disk (#{size_gib} GiB) is smaller than the base image (#{capacity} bytes)"
      end

      def require_base!(base)
        raise Error, 'Verified VM base image is missing' unless base.file? && !base.symlink?
      end

      def verify_base!(base)
        result = @runner.run(@engine.image_tool, arguments: ['info', '--output=json', base.to_s], timeout: 10)
        verify_result!(result, 'Cannot inspect verified VM base image')

        metadata = JSON.parse(result.stdout)
        return metadata if metadata.is_a?(Hash) && metadata['format'] == 'qcow2' && !metadata.key?('backing-filename')

        raise Error, 'VM base image must be a standalone QCOW2 image'
      rescue JSON::ParserError
        raise Error, 'Malformed QEMU base-image metadata', cause: nil
      end

      def create_overlay!(base, overlay)
        result = @runner.run(@engine.image_tool, arguments: ['create', '-f', 'qcow2', '-F', 'qcow2',
                                                             '-b', base.to_s, overlay.to_s], timeout: 30)
        verify_result!(result, 'QEMU overlay creation failed')

        File.chmod(0o600, overlay)
      end

      def resize_overlay!(overlay, size_gib)
        result = @runner.run(@engine.image_tool,
                             arguments: ['resize', '--preallocation=off', '-f', 'qcow2', overlay.to_s, "#{size_gib}G"],
                             timeout: 30)
        verify_result!(result, 'QEMU overlay sizing failed for vm.disk')
      end

      def verify_result!(result, operation)
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: operation, tool: 'qemu-img')
        raise Error, "#{operation}\n#{details}", cause: nil
      end

      def overlay_metadata(overlay)
        result = @runner.run(@engine.image_tool, arguments: ['info', '--output=json', overlay.to_s], timeout: 10)
        verify_result!(result, 'Cannot inspect VM overlay')

        data = JSON.parse(result.stdout)
        raise Error, 'Malformed QEMU overlay metadata' unless data.is_a?(Hash)

        data
      rescue JSON::ParserError
        raise Error, 'Malformed QEMU overlay metadata', cause: nil
      end

      def node_directory(hostname)
        raise Error, 'Invalid VM hostname' unless Node::Inventory.valid_name?(hostname) &&
                                                  hostname == hostname.downcase

        @workspace_directory.join('vms', hostname)
      end
    end
  end
end
