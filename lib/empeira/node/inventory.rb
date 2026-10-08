# frozen_string_literal: true

module Empeira
  module Node
    module Inventory
      def self.valid?(nodes)
        return false unless nodes.is_a?(Hash)

        nodes.all? { |name, record| valid_record?(name, record) }
      end

      def self.valid_record?(name, record)
        return false unless record.is_a?(Hash) && record['hostname'] == name && valid_name?(name)
        return false unless CommandMocks.valid_inventory?(record.fetch('command_mocks', {}))

        case record['provider']
        when 'container' then valid_container?(record)
        when 'vm' then valid_vm?(name, record)
        else false
        end
      end

      def self.valid_container?(record)
        Runtime.registry.names.include?(record['runtime']) &&
          [true, false].include?(record['provisioned']) &&
          valid_definition?(record) && valid_metadata?(record) && valid_ssh?(record)
      end

      def self.valid_ssh?(record)
        return true unless record.key?('ssh_host') || record.key?('ssh_port')

        record['ssh_host'] == '127.0.0.1' && %w[loopback tunnel].include?(record['ssh_transport']) &&
          (record['ssh_port'].nil? || (record['ssh_port'].is_a?(Integer) && record['ssh_port'].between?(1, 65_535)))
      end

      def self.valid_vm?(name, record)
        valid_vm_image?(record['base_image']) && valid_vm_process?(record) &&
          valid_vm_network?(name, record) && valid_vm_metadata?(record)
      end

      def self.valid_vm_image?(image)
        return false unless image.is_a?(Hash)

        required = %w[distribution version architecture source revision checksum]
        required.all? { |key| image[key].is_a?(String) && !image[key].empty? } &&
          image['source'].start_with?('https://') &&
          image['checksum'].match?(/\A[0-9a-f]{64}\z/)
      end

      def self.valid_vm_process?(record)
        record['engine'] == 'qemu' && %w[kvm hvf].include?(record['accelerator']) &&
          %w[amd64 arm64].include?(record['architecture']) &&
          valid_vm_resources?(record) && valid_vm_identity?(record)
      end

      def self.valid_vm_resources?(record)
        %w[memory cpus].all? { |key| record[key].is_a?(Integer) && record[key].positive? } &&
          record['ssh_port'].is_a?(Integer) && record['ssh_port'].between?(1024, 65_535)
      end

      def self.valid_vm_identity?(record)
        (record['pid'].nil? || (record['pid'].is_a?(Integer) && record['pid'].positive?)) &&
          %w[preparing running stopped].include?(record['state'])
      end

      def self.valid_vm_network?(name, record)
        record['overlay'] == "vms/#{name}/disk.qcow2" &&
          record['network'].is_a?(String) && record['network'].match?(/\A[a-f0-9]{24}:environment\z/) &&
          record['mac_address'].is_a?(String) &&
          record['mac_address'].match?(/\A52:54:(?:[0-9a-f]{2}:){3}[0-9a-f]{2}\z/)
      end

      def self.valid_vm_metadata?(record)
        valid_certificate?(record['certificate_key']) && [true, false].include?(record['provisioned']) &&
          %w[os version created_at].all? { |key| record[key].is_a?(String) && !record[key].empty? }
      end

      def self.valid_definition?(record)
        definition = record['definition']
        definition.is_a?(Hash) && definition['hostname'] == record['hostname'] &&
          definition['image'] == record['image'] && valid_id?(record['id'])
      end

      def self.valid_metadata?(record)
        %w[amd64 arm64].include?(record['architecture']) && valid_certificate?(record['certificate_key']) &&
          %w[os version image created_at].all? do |key|
            record[key].is_a?(String) && !record[key].empty?
          end
      end

      def self.valid_certificate?(key)
        key.nil? || (key.is_a?(String) && key.match?(/\A[a-f0-9]{64}\z/))
      end

      def self.valid_id?(id)
        id.nil? || (id.is_a?(String) && id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/))
      end

      def self.valid_name?(name)
        name.is_a?(String) && name.size <= 253 &&
          name.split('.', -1).all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
      end
    end
  end
end
