# frozen_string_literal: true

require 'fileutils'
require 'digest'

module Empeira
  module Node
    # Per-node credentials and known hosts stay in private workspace storage.
    class SSHCredentials
      def initialize(context:, runner:, provider:, hostname:, purpose: nil, instance: nil)
        @runner = runner
        raise ArgumentError, 'Unknown SSH credential scope' unless [nil, :system].include?(purpose)

        @purpose = purpose
        @instance = instance
        parent = provider == 'vm' ? 'vms' : 'containers'
        @directory = context.locations.workspace(context.workspace).join(parent, hostname)
      end

      attr_reader :directory

      def key_path
        directory.join('id_ed25519')
      end

      def public_path
        Pathname("#{key_path}.pub")
      end

      def known_hosts
        root = @instance ? directory.join('sessions', Digest::SHA256.hexdigest(@instance)) : directory
        root.join(@purpose ? "#{@purpose}_known_hosts" : 'known_hosts')
      end

      def prepare
        prepare_hosts
        generate unless [key_path, public_path].any? { |path| path.exist? || path.symlink? }
        verify!
        public_path
      end

      # rubocop:disable-next Metrics/AbcSize -- Validate both the private host directory and the instance-specific known-hosts path.
      def prepare_hosts
        raise Error, 'Managed SSH directory must not be a symlink' if directory.symlink?

        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        prepare_session_directory if known_hosts.dirname != directory
        raise Error, 'Managed SSH known_hosts is unsafe' if known_hosts.symlink? ||
                                                            (known_hosts.exist? && !known_hosts.file?)
      end

      def verify!
        raise Error, 'Managed SSH directory must not be a symlink' if directory.symlink?

        raise Error, 'Managed SSH key material is missing or unsafe; destroy and recreate the node' unless safe_keys?
        raise Error, 'Managed SSH known_hosts must not be a symlink' if known_hosts.symlink?

        File.chmod(0o600, key_path)
        File.chmod(0o600, known_hosts) if known_hosts.exist?
      end

      def cleanup
        raise Error, 'Managed SSH directory must not be a symlink' if directory.symlink?

        FileUtils.remove_entry_secure(directory) if directory.exist?
      end

      private

      def prepare_session_directory
        [directory.join('sessions'), known_hosts.dirname].each do |path|
          raise Error, 'Managed SSH session directory must not be a symlink' if path.symlink?

          FileUtils.mkdir_p(path, mode: 0o700)
        end
      end

      def safe_keys?
        [key_path, public_path].all? { |path| path.file? && !path.symlink? && path.readable? }
      end

      def generate
        result = @runner.run('ssh-keygen', arguments: ['-q', '-t', 'ed25519', '-C', 'empeira-managed',
                                                       '-N', '', '-f', key_path.to_s],
                                           timeout: 15)
        raise Error, 'Cannot create managed SSH key; install openssh-client on the CLI host' unless result.success?
      end
    end
  end
end
