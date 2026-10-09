# frozen_string_literal: true

require 'uri'

module Empeira
  module Modules
    # Source acquisition deliberately uses the invoking user's Git/OpenSSH context.
    # Persistent bare repositories are mounted read-only; SSH credentials never enter the helper.
    class HostGit
      def initialize(runner:, project:, progress: Progress.new)
        @runner = runner
        @project = project
        @progress = progress
      end

      # rubocop:disable-next Metrics/AbcSize -- Acquire each host source and notify its module before network access.
      def prepare(entries, directory:)
        validate!(entries)
        entries.to_h do |entry|
          block_given? ? yield(entry.fetch('name')) : @progress.heartbeat(entry.fetch('name'))
          mirror = source_path(directory, entry.fetch('remote'))

          result = clone(acquisition_arguments(entry.fetch('remote'), mirror))
          fail_acquisition(entry.fetch('name'), result) unless result.success?
          [entry.fetch('name'), mirror.to_s]
        end
      end

      private

      def source_path(directory, remote)
        path = Pathname(directory).join("#{Digest::SHA256.hexdigest(remote)}.git")
        raise Error, 'Git source cache must not be a symlink' if path.symlink?

        path
      end

      def acquisition_arguments(remote, mirror)
        return ['clone', '--mirror', '--template=', '--', remote, mirror.to_s] unless mirror.exist?

        ['-C', mirror.to_s, 'fetch', '--prune', '--force', '--', remote, '+refs/*:refs/*']
      end

      def fail_acquisition(name, result)
        diagnostic = Execution::Diagnostics.native(result, operation: "Acquire Git source for #{name}", tool: 'git/ssh')
        raise Error, "Module: #{name}\nError: Git source acquisition failed" \
                     "#{' (timed out)' if result.timed_out}\n\ngit/ssh output:\n#{diagnostic}", cause: nil
      end

      def clone(arguments)
        if $stdin.tty? && $stderr.tty?
          @runner.buffered('git', arguments: arguments, directory: @project)
        else
          @runner.run('git', arguments: arguments, directory: @project, timeout: 300)
        end
      end

      def validate!(entries)
        unless entries.is_a?(Array) && entries.all? { |entry| valid_entry?(entry) } &&
               entries.map { |entry| entry['name'] }.uniq.size == entries.size
          raise Error, 'Puppetfile installer returned an invalid Git source plan'
        end
      end

      def valid_entry?(entry)
        entry.is_a?(Hash) && entry.keys.sort == %w[name remote] &&
          entry['name'].is_a?(String) && entry['name'].match?(Configuration::HieraMountSchema::NAME) &&
          valid_remote?(entry['remote'])
      end

      def valid_remote?(remote)
        return false unless remote.is_a?(String) && !remote.start_with?('-') && !remote.match?(/[\x00-\x1f]/)
        return remote.match?(/\A(?:[\w.-]+@)?[\w.-]+:[^:].*\z/) unless remote.include?('://')

        valid_uri?(URI.parse(remote))
      rescue URI::InvalidURIError
        false
      end

      def valid_uri?(uri)
        %w[ssh http https].include?(uri.scheme) && uri.host && !uri.host.start_with?('-') &&
          (uri.scheme == 'ssh' ? uri.password.nil? : uri.userinfo.nil?)
      end
    end
  end
end
