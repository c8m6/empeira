# frozen_string_literal: true

require 'json'
require 'socket'
require 'timeout'

module SharedNetworkProof
  class Failure < StandardError; end

  class Commands
    def initialize(runner: Empeira::Execution::Runner.new)
      @runner = runner
    end

    def run(*arguments, timeout: 30, environment: {}, directory: nil)
      result = @runner.run(arguments.first, arguments: arguments.drop(1), timeout: timeout,
                                            environment: environment, directory: directory)
      raise Failure, failure_message(arguments.first, result, environment.values) unless result.success?

      result.stdout
    end

    def diagnostic(output, sensitive = [])
      text = output.to_s.dup
      sensitive.compact.reject(&:empty?).each { |value| text.gsub!(value, '[REDACTED]') }
      excerpt = text.byteslice(0, 2000).inspect
      text.bytesize > 2000 ? "#{excerpt} [truncated]" : excerpt
    end

    def podman(*, **)
      run('podman', '--remote=false', *, **)
    end

    def namespace(*)
      podman('unshare', '--rootless-netns', *)
    end

    def available?(name)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, name)
        File.file?(path) && File.executable?(path)
      end
    end

    private

    def failure_message(executable, result, sensitive)
      # Only synthetic fixture output is captured; never print arguments or environment values.
      "#{File.basename(executable)} failed (exit=#{result.exit_status.inspect}, timeout=#{result.timed_out}): " \
        "stdout=#{diagnostic(result.stdout, sensitive)} stderr=#{diagnostic(result.stderr, sensitive)}"
    end
  end

  module Ownership
    LABEL = 'io.empeira.shared-network-proof'

    def self.verify!(observed, id:, token:)
      labels = observed['Labels'] || observed['labels'] || observed.dig('Config', 'Labels')
      actual = observed['Id'] || observed['id']
      return if actual == id && labels&.fetch(LABEL, nil) == token

      raise Failure, 'Proof resource ID/ownership mismatch; refusing cleanup'
    end
  end

  class Prerequisites
    def self.check!(commands: Commands.new)
      missing = missing_capabilities(commands)
      raise Failure, "Shared network proof blocked: #{missing.join('; ')}" unless missing.empty?

      info = JSON.parse(commands.podman('info', '--format', 'json'))
      unless info.dig('host', 'security', 'rootless') && info.dig('host', 'networkBackend') == 'netavark'
        raise Failure, 'Proof requires local rootless Podman with Netavark; no rootful fallback'
      end

      verify_namespace(commands)
      report_versions(commands, info)
    end

    def self.report_versions(commands, info)
      puts JSON.generate(podman: info['version'], network: info.dig('host', 'networkBackendInfo'),
                         qemu: commands.run('qemu-system-x86_64', '--version').lines.first,
                         kernel: commands.run('uname', '-r').strip)
    end

    def self.verify_namespace(commands)
      commands.podman('unshare', 'true')
      return if commands.podman('unshare', '--help').include?('--rootless-netns')

      raise Failure, 'Installed Podman lacks unshare --rootless-netns'
    end

    def self.missing_devices
      missing = []
      %w[/dev/net/tun /dev/kvm].each do |path|
        missing << "read/write #{path}" unless File.readable?(path) && File.writable?(path)
      end
      missing
    end

    def self.missing_capabilities(commands)
      missing = []
      unless RUBY_PLATFORM.include?('linux') && RUBY_PLATFORM.include?('x86_64')
        missing << 'Linux amd64 host (WSL2 is Linux)'
      end
      missing << 'ordinary non-root user' if Process.uid.zero?
      %w[podman qemu-system-x86_64 ip nsenter go curl].each do |tool|
        missing << "host executable #{tool}" unless commands.available?(tool)
      end
      missing.concat(missing_devices)
      missing
    end
  end
end
