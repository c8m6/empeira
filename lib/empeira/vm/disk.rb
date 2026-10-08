# frozen_string_literal: true

require 'fileutils'
require 'json'

module Empeira
  module VM
    # One writable QCOW2 overlay per node; the shared base remains read-only.
    class Disk
      def initialize(engine:, runner:, workspace_directory:)
        @engine = engine
        @runner = runner
        @workspace_directory = workspace_directory
      end

      def create(hostname:, base:)
        directory = node_directory(hostname)
        FileUtils.mkdir_p(directory, mode: 0o700)
        overlay = directory.join('disk.qcow2')
        raise Providers::AlreadyExists, 'VM overlay already exists' if overlay.exist? || overlay.symlink?

        require_base!(base)
        verify_base!(base)
        create_overlay!(base, overlay)
        overlay
      end

      def verify!(hostname:, base:)
        overlay = node_directory(hostname).join('disk.qcow2')
        raise Error, 'VM overlay is missing or unsafe' unless overlay.file? && !overlay.symlink?

        data = overlay_metadata(overlay)
        unless data['format'] == 'qcow2' && data['backing-filename'] == base.to_s &&
               data['backing-filename-format'] == 'qcow2'
          raise Providers::OwnershipError, 'VM overlay backing image differs from recorded base'
        end

        overlay
      end

      def remove(hostname:, base:)
        overlay = verify!(hostname: hostname, base: base)
        File.unlink(overlay)
        overlay
      end

      private

      def require_base!(base)
        raise Error, 'Verified VM base image is missing' unless base.file? && !base.symlink?
      end

      def verify_base!(base)
        result = @runner.run(@engine.image_tool, arguments: ['info', '--output=json', base.to_s], timeout: 10)
        raise Error, 'Cannot inspect verified VM base image' unless result.success?

        metadata = JSON.parse(result.stdout)
        return if metadata['format'] == 'qcow2' && !metadata.key?('backing-filename')

        raise Error, 'VM base image must be a standalone QCOW2 image'
      rescue JSON::ParserError
        raise Error, 'Malformed QEMU base-image metadata', cause: nil
      end

      def create_overlay!(base, overlay)
        result = @runner.run(@engine.image_tool, arguments: ['create', '-f', 'qcow2', '-F', 'qcow2',
                                                             '-b', base.to_s, overlay.to_s], timeout: 30)
        raise Error, 'QEMU overlay creation failed' unless result.success?

        File.chmod(0o600, overlay)
      end

      def overlay_metadata(overlay)
        result = @runner.run(@engine.image_tool, arguments: ['info', '--output=json', overlay.to_s], timeout: 10)
        raise Error, 'Cannot inspect VM overlay' unless result.success?

        JSON.parse(result.stdout)
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
