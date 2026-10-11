# frozen_string_literal: true

require 'json'

module Empeira
  module VM
    # Observe cloud-init growth before package bootstrap without changing guest partitions.
    class RootDisk
      ALIGNMENT_MARGIN = 16 * (1024**2)

      def initialize(guest:)
        @guest = guest
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
        root_size = byte_size(root)
        return if capacity.between?(root_size * 95 / 100, root_size)

        raise Error, "VM root filesystem has not grown: #{root.fetch('name')} partition=#{root_size} bytes, " \
                     "filesystem=#{capacity} bytes; inspect cloud-init logs"
      end

      def observe(record, arguments)
        result = @guest.run(record, arguments)
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
        disk_size = byte_size(disk)
        return if disk_size == expected && free.between?(0, ALIGNMENT_MARGIN)

        raise Error, "VM root partition has not grown: #{root.fetch('name')}, disk=#{disk_size} bytes, " \
                     "expected=#{expected} bytes, unpartitioned=#{free} bytes; inspect cloud-init logs"
      end

      def unpartitioned(disk)
        partitions = disk.fetch('children').select { |device| device['type'] == 'part' }
        sizes = [byte_size(disk), *partitions.map { |partition| byte_size(partition) }]

        sizes.first - sizes.drop(1).sum
      end

      def byte_size(device)
        size = device.fetch('size')
        size = Integer(size, 10) if size.is_a?(String) && size.match?(/\A[0-9]+\z/)
        raise TypeError unless size.is_a?(Integer) && size.positive?

        size
      end
    end
  end
end
