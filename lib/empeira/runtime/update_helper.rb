# frozen_string_literal: true

module Empeira
  module Runtime
    # Disposable update tooling: no service plan, workspace networking or persistent inventory.
    module UpdateHelper
      PROXY_VARIABLES = %w[HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy].freeze

      def with_update_helper(image:, input:, output:, sources:, cache:)
        # Reuse the ownership verifier, but assign a unique identity for this invocation only.
        identity = Empeira::Services::Definition.new(key: "update-#{SecureRandom.hex(16)}",
                                                     workspace: context.workspace)
        update_command(helper_arguments(identity, image, input, output, sources, cache), operation: 'helper creation')
        resource = inspect_service(identity)
        raise Providers::ExecutionError, 'Update helper creation could not be verified' unless resource

        update_command(['start', resource.fetch('id')], operation: 'helper start')
        verify_helper_network!(identity, resource.fetch('id'))
        yield resource
      ensure
        remove_update_helper(identity, resource&.fetch('id')) if identity
      end

      def update_command(arguments, operation:, timeout: 600, registry: nil)
        result = runner.run(name, arguments: arguments, timeout: timeout)
        return result if result.success?

        diagnostic = Execution::Diagnostics.safe_text("#{result.stderr}\n#{result.stdout}")
        guidance = if registry
                     registry_failure_hint(registry, diagnostic, timed_out: result.timed_out)
                   else
                     'Check your normal host/container network access.'
                   end
        raise Providers::ExecutionError, "#{name} update #{operation} failed " \
                                         "(#{result.timed_out ? 'timeout' : result.exit_status}). " \
                                         "#{guidance}\n" \
                                         "#{Execution::Diagnostics.native(result, operation: operation, tool: name)}",
              cause: nil
      end

      private

      # rubocop:disable-next Metrics/AbcSize -- Keep all explicit module-helper mounts and restrictions together.
      def helper_arguments(identity, image, input, output, sources, cache)
        mounts = %w[Puppetfile request.json].flat_map do |file|
          ['--mount', helper_mount(File.join(input, file), "/work/#{file}", readonly: true)]
        end
        environment = { 'HOME' => '/work', 'GIT_TERMINAL_PROMPT' => '0', 'GIT_ALLOW_PROTOCOL' => 'file' }
        ['create', '--name', identity.name, '--network', update_helper_network, *update_helper_user,
         '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', *label_arguments(identity),
         *PROXY_VARIABLES.select { |key| ENV.key?(key) }.flat_map { |key| ['--env', key] },
         *environment.flat_map { |key, value| ['--env', "#{key}=#{value}"] },
         *mounts, '--mount', helper_mount(output, '/work/modules', readonly: false),
         '--mount', helper_mount(sources, sources.to_s, readonly: true),
         '--mount', helper_mount(cache, cache.to_s, readonly: false), image]
      end

      def update_helper_user
        ['--user', "#{Process.uid}:#{Process.gid}"]
      end

      def helper_mount(source, target, readonly:)
        if source.to_s.match?(/[,\r\n]/)
          raise ConfigurationError,
                'Update mount paths must not contain commas or newlines'
        end

        "type=bind,src=#{File.realpath(source)},dst=#{target}#{',readonly' if readonly}"
      end

      def verify_helper_network!(identity, id)
        resource = inspect_service(identity, expected_id: id)
        raise Providers::ExecutionError, 'Update helper disappeared before synchronization' unless resource

        networks = resource.fetch('networks').keys
        return if networks == [update_helper_network] && resource.fetch('dns').empty? &&
                  resource.fetch('ports').empty? && resource.fetch('published_ports', {}).values.all?(&:nil?)

        raise Providers::OwnershipError, 'Update helper has unexpected network, DNS or port configuration'
      end

      def update_helper_network
        'bridge'
      end

      def remove_update_helper(identity, id)
        resource = inspect_service(identity, expected_id: id)
        return unless resource

        update_command(['rm', '--force', '--volumes', resource.fetch('id')], operation: 'helper removal')
        raise Providers::ExecutionError, 'Update helper removal could not be verified' if inspect_service(identity)
      end
    end

    Container.include(UpdateHelper)
  end
end
