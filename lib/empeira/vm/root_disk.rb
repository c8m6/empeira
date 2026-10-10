# frozen_string_literal: true

require 'json'

module Empeira
  module VM
    # Observe cloud-init growth before package bootstrap without changing guest partitions.
    class RootDisk
      ALIGNMENT_MARGIN = 16 * (1024**2)

      def initialize(ssh:)
        @ssh = ssh
      end

      def verify!(record, size_gib:)
        data = JSON.parse(observe(record, %w[lsblk --json --bytes --paths --output NAME,TYPE,SIZE,MOUNTPOINT]))
        raise TypeError unless data.is_a?(Hash)

        root, disk = root_device(data.fetch('blockdevices'))
        verify_partition!(root, disk, size_gib * Disk::GIB)
        verify_filesystem!(record, root)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError
        raise Error, 'Cannot verify VM root disk growth: malformed guest disk metadata; inspect cloud-init logs',
              cause: nil
      end

      private

      def verify_filesystem!(record, root)
        capacity = Integer(observe(record, ['df', '--block-size=1', '--output=size', '/']).lines.last, 10)
        return if capacity.between?(root.fetch('size') * 95 / 100, root.fetch('size'))

        raise Error, "VM root filesystem has not grown: #{root.fetch('name')} partition=#{root.fetch('size')} bytes, " \
                     "filesystem=#{capacity} bytes; inspect cloud-init logs"
      end

      def observe(record, arguments)
        result = @ssh.run(record, arguments)
        return result.stdout if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Verify VM root disk growth', tool: arguments.first)
        raise Error, "Cannot verify VM root disk growth\n#{details}", cause: nil
      end

      def root_device(devices)
        roots = device_pairs(devices).select { |device, _parent| device['mountpoint'] == '/' }
        unless roots.size == 1
          raise Error,
                'Cannot identify a unique VM root partition from lsblk; inspect cloud-init logs'
        end

        root, disk = roots.first
        unless root['type'] == 'part' && disk && disk['type'] == 'disk'
          raise Error, 'Cannot verify VM root growth for this block-device layout; inspect cloud-init logs'
        end

        [root, disk]
      end

      def device_pairs(devices, parent = nil)
        raise TypeError unless devices.is_a?(Array) && devices.all?(Hash)

        devices.flat_map { |device| [[device, parent], *device_pairs(device.fetch('children', []), device)] }
      end

      def verify_partition!(root, disk, expected)
        free = unpartitioned(disk)
        return if disk.fetch('size') == expected && free.between?(0, ALIGNMENT_MARGIN)

        raise Error, "VM root partition has not grown: #{root.fetch('name')}, disk=#{disk.fetch('size')} bytes, " \
                     "expected=#{expected} bytes, unpartitioned=#{free} bytes; inspect cloud-init logs"
      end

      def unpartitioned(disk)
        partitions = disk.fetch('children').select { |device| device['type'] == 'part' }
        sizes = [disk.fetch('size'), *partitions.map { |partition| partition.fetch('size') }]
        raise TypeError unless sizes.all? { |size| size.is_a?(Integer) && size.positive? }

        sizes.first - sizes.drop(1).sum
      end
    end
  end
end
