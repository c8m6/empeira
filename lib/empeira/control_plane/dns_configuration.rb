# frozen_string_literal: true

module Empeira
  module ControlPlane
    # Validate and observe the actual CoreDNS generation under the workspace lock.
    # rubocop:disable-next Metrics/ClassLength -- Candidate validation and rollback form one transaction.
    class DNSConfiguration
      VALIDATOR = 'dns-validation'
      PROBE = <<~RUBY
        require 'resolv'
        dns = Resolv::DNS.new(nameserver: [ARGV[0]], search: [], ndots: 1)
        dns.timeouts = 1
        answers = dns.getresources('_empeira-config.empeira.internal', Resolv::DNS::Resource::IN::TXT)
        exit(answers.any? { |answer| answer.data == ARGV[1] } ? 0 : 1)
      RUBY

      def initialize(plan:, runtime:, inventory:, persist:)
        @plan = plan
        @runtime = runtime
        @inventory = inventory
        @persist = persist
        @files = plan.files
      end

      # rubocop:disable-next Naming/PredicateMethod -- Returns whether the activation changed infrastructure.
      def activate(content, resources:)
        @server = resources.fetch('server')
        @dns = resources.fetch('dns')
        address = @dns.dig('networks', @plan.network, 'IPAddress')
        current = File.binread(@files.path('Corefile'))
        verified = active?(address, current)
        @files.write('Corefile.last-good', current) if verified
        return false if current == content && verified

        validate(content)
        publish(content, address)
        true
      end

      private

      def generation(content)
        content[/0 IN TXT \\"([a-f0-9]{64})/, 1]
      end

      def active?(address, content)
        expected = generation(content)
        return false unless expected

        @runtime.service_exec(@server, [Health::RUBY, '-e', PROBE, address, expected], timeout: 5).success?
      end

      def wait(address, content, definition:, id:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @plan.config.dig('server', 'timeout')
        loop do
          resource = @runtime.inspect_service(definition, expected_id: id)
          require_running!(resource)
          return if active?(address, content)
          raise Error, 'CoreDNS did not activate the expected configuration within server.timeout' if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
      end

      def validator_definition
        options = @plan.definitions.fetch('dns').options.slice('image', 'network', 'memory', 'mounts')
        Services::Definition.new(key: VALIDATOR, workspace: @plan.context.workspace,
                                 **options.transform_keys(&:to_sym), read_only: true,
                                 cap_drop: ['ALL'], cap_add: ['NET_BIND_SERVICE'],
                                 security_options: ['no-new-privileges'],
                                 command: ['-conf', '/empeira/Corefile.next'])
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Persist helper intent before creation and always remove it.
      def validate(content)
        definition = validator_definition
        remove_validator(definition) if @inventory.fetch('services').key?(VALIDATOR)
        @files.write('Corefile.next', content)
        @inventory.fetch('services')[VALIDATOR] = { 'id' => nil }
        @persist.call
        resource = @runtime.create_service(definition)
        @inventory.fetch('services')[VALIDATOR]['id'] = resource.fetch('id')
        @persist.call
        @runtime.start_service(resource)
        resource = @runtime.inspect_service(definition, expected_id: resource.fetch('id'))
        address = validator_address(resource)
        wait(address, content, definition: definition, id: resource.fetch('id'))
      rescue StandardError => e
        raise Error, "CoreDNS candidate validation failed; active Corefile preserved\n#{e.message}", cause: e
      ensure
        remove_validator(definition) if definition && @inventory.fetch('services').key?(VALIDATOR)
      end

      def remove_validator(definition)
        id = @inventory.fetch('services').fetch(VALIDATOR).fetch('id')
        @runtime.remove_service(definition, expected_id: id)
        @inventory.fetch('services').delete(VALIDATOR)
        @persist.call
      end

      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity -- Verify the helper's entire network exposure before using it.
      def validator_address(resource)
        require_running!(resource)
        address = resource.dig('networks', @plan.network, 'IPAddress')
        unless address && !address.empty? && IPAddr.new(address).ipv4? &&
               resource.fetch('networks').keys == [@plan.network] &&
               resource.fetch('ports').empty? && resource.fetch('published_ports', {}).values.all?(&:nil?)
          raise Error, 'CoreDNS validation helper has unexpected network attachments, ports or IPv4 address'
        end

        address
      end

      def require_running!(resource)
        return if resource && resource['state'] == 'running'

        details = resource ? @runtime.service_logs(resource) : 'missing process'
        raise Error, "CoreDNS configuration process failed to start or stopped: #{details}"
      end

      def publish(content, address)
        backup = @files.path('Corefile.last-good')
        previous = File.binread(File.file?(backup) ? backup : @files.path('Corefile'))
        begin
          @files.write('Corefile', content)
          reload(content, address)
        rescue StandardError, Interrupt => e
          restore(previous, address, e)
          raise e.exception("CoreDNS activation failed; previous Corefile restored\n#{e.message}"), cause: e
        end
        @files.write('Corefile.last-good', content)
      end

      def reload(content, address)
        @runtime.reload_service(@dns, signal: 'USR1')
        wait(address, content, definition: @plan.definitions.fetch('dns'), id: @dns.fetch('id'))
      end

      def restore(previous, address, error)
        @files.write('Corefile', previous)
        unless generation(previous)
          @runtime.reload_service(@dns, signal: 'USR1')
          raise Error, 'The previous Corefile predates activation verification; inspect owned DNS logs'
        end

        reload(previous, address)
      rescue StandardError => e
        raise Error, "CoreDNS activation failed: #{error.message}\nPrevious Corefile restored on disk, but " \
                     "reactivation could not be verified: #{e.message}", cause: error
      end
    end
  end
end
