# frozen_string_literal: true

require 'fileutils'
require 'yaml'

module Empeira
  module VM
    # Private NoCloud material is removed after initial guest configuration.
    # rubocop:disable-next Metrics/ClassLength -- Seed, key and bootstrap material are one guest boundary.
    class CloudInit
      USER = 'empeira'

      def initialize(context:, runner:, executable_path: ENV.fetch('PATH', ''))
        @context = context
        @runner = runner
        @executable_path = executable_path
      end

      def prepare(record)
        directory = node_directory(record.fetch('hostname'))
        FileUtils.mkdir_p(directory, mode: 0o700)
        credentials = Node::SSHCredentials.new(context: @context, runner: @runner, provider: 'vm',
                                               hostname: record.fetch('hostname'))
        credentials.prepare
        key = credentials.key_path
        files = seed_files(directory, record, File.read("#{key}.pub").strip)
        create_iso(directory, files)
      end

      def finish(record, ssh:)
        directory = node_directory(record.fetch('hostname'))
        files = seed_files(directory, record, File.read("#{key_path(record.fetch('hostname'))}.pub").strip,
                           console: false)
        create_iso(directory, files)
        paths = %w[user-data.txt user-data.txt.i cloud-config.txt obj.pkl].map do |name|
          "/var/lib/cloud/instance/#{name}"
        end
        result = ssh.run(record, ['rm', '-f', *paths])
        return if result.success?

        details = Execution::Diagnostics.command(result, operation: 'Guest cloud-init credential cleanup', tool: 'rm')
        raise Error, "Cannot remove temporary guest cloud-init credentials\n#{details}", cause: nil
      end

      def key_path(hostname)
        node_directory(hostname).join('id_ed25519')
      end

      def validate!
        bootstrap_files
      end

      private

      def create_iso(directory, files)
        output = directory.join('seed.iso')
        tool = locate('xorriso') || raise(UnavailableFeature, 'xorriso is required for VM cloud-init seeds')
        Tempfile.create(['seed-', '.iso'], directory) do |temporary|
          result = @runner.run(tool, arguments: ['-as', 'mkisofs', '-quiet', '-volid', 'cidata',
                                                 '-output', temporary.path, *files.map(&:to_s)], timeout: 30)
          raise Error, 'Cannot create VM cloud-init seed' unless result.success?

          File.chmod(0o600, temporary.path)
          File.rename(temporary.path, output)
        end
        output
      ensure
        files&.each { |path| FileUtils.rm_f(path) }
      end

      def seed_files(directory, record, public_key, console: true)
        data = cloud_config(record, public_key, console: console)
        metadata = { 'instance-id' => "#{@context.workspace.id}-#{record.fetch('hostname')}",
                     'local-hostname' => record.fetch('hostname') }
        network = network_config(record)
        { 'user-data' => "#cloud-config\n#{YAML.dump(data)}", 'meta-data' => YAML.dump(metadata),
          'network-config' => YAML.dump(network) }.map do |name, content|
          path = directory.join(name)
          File.write(path, content, mode: 'w', perm: 0o600)
          File.chmod(0o600, path)
          path
        end
      end

      def network_config(record)
        { 'version' => 2, 'ethernets' => {
          'peer' => { 'match' => { 'macaddress' => record.fetch('mac_address') }, 'set-name' => 'eth0',
                      'addresses' => ["#{record.fetch('peer').fetch('ip')}/24"], 'dhcp4' => false, 'dhcp6' => false,
                      'routes' => [{ 'to' => '0.0.0.0/0', 'via' => record.fetch('peer').fetch('gateway') }],
                      'link-local' => [], 'nameservers' => { 'addresses' => [record.fetch('peer').fetch('dns')] } },
          'management' => { 'match' => { 'macaddress' => Network::Peer::Management.new(record).mac },
                            'set-name' => 'eth1', 'dhcp4' => true, 'dhcp6' => false, 'link-local' => [],
                            'dhcp4-overrides' => { 'use-dns' => false, 'use-routes' => false } }
        } }
      end

      def cloud_config(record, public_key, console: true)
        scripts = bootstrap_files
        { 'hostname' => record.fetch('hostname').split('.').first,
          'fqdn' => record.fetch('hostname'), 'manage_etc_hosts' => true,
          'users' => [{ 'name' => USER, 'sudo' => 'ALL=(ALL) NOPASSWD:ALL',
                        'shell' => '/bin/bash', 'ssh_authorized_keys' => [public_key] }],
          'ssh_pwauth' => false, 'disable_root' => true,
          'write_files' => cloud_files(scripts), 'runcmd' => cloud_commands(scripts),
          **(console ? console_password : {}) }
      end

      def console_password
        password = @context.configuration.dig('vm', 'console', 'root_password')
        return {} unless password

        { 'chpasswd' => { 'expire' => false,
                          'users' => [{ 'name' => 'root', 'password' => password, 'type' => 'text' }] } }
      end

      def cloud_files(scripts)
        Node::Bootstrap.new(provider: 'vm').files.map do |file|
          { 'path' => file.path, 'permissions' => format('%04o', file.mode), 'content' => file.content }
        end + [{ 'path' => '/etc/sysctl.d/90-empeira-ipv4.conf', 'permissions' => '0644',
                 'content' => "net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n" }] + scripts
      end

      def cloud_commands(scripts)
        [['sysctl', '--system'], *scripts.map { |entry| [entry.fetch('path')] }]
      end

      def bootstrap_files
        config = @context.configuration.fetch('bootstrap')
        return [] unless config.fetch('enabled')

        config.fetch('scripts').each_with_index.map { |relative, index| bootstrap_entry(relative, index) }
      end

      def bootstrap_entry(relative, index)
        source = @context.project.path.join(relative).realpath
        unless source.file? && source.to_s.start_with?("#{@context.project.path}/") && source.size <= 1_000_000
          raise ConfigurationError, "bootstrap.scripts.#{index} must be a project-local file below 1 MB"
        end

        content = File.read(source, encoding: 'UTF-8')
        raise ConfigurationError, "bootstrap.scripts.#{index} must be UTF-8" unless content.valid_encoding?

        { 'path' => "/usr/local/libexec/empeira-bootstrap-#{index}", 'permissions' => '0700',
          'content' => content }
      rescue SystemCallError
        raise ConfigurationError, "bootstrap.scripts.#{index} must resolve to a project-local file", cause: nil
      end

      def node_directory(hostname)
        @context.locations.workspace(@context.workspace).join('vms', hostname)
      end

      def locate(name)
        @executable_path.split(File::PATH_SEPARATOR).filter_map do |directory|
          path = Pathname(directory).join(name)
          path.to_s if path.file? && path.executable?
        end.first
      end
    end
  end
end
