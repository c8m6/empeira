# frozen_string_literal: true

module Empeira
  module Runtime
    class ServiceArguments
      SCALARS = { 'dns' => '--dns', 'user' => '--user', 'entrypoint' => '--entrypoint',
                  'env_file' => '--env-file', 'shm_size' => '--shm-size', 'mac_address' => '--mac-address',
                  'ip' => '--ip', 'runtime_ip' => '--ip' }.freeze

      def initialize(definition)
        @definition = definition
        @options = definition.options
      end

      # One declarative argument vector makes runtime options auditable.
      # rubocop:disable-next Metrics/AbcSize
      def build
        ['create', '--pull=never', '--name', @definition.name,
         '--hostname', @options.fetch('hostname', @definition.key),
         '--network', @options.fetch('network'), '--memory', "#{@options.fetch('memory')}m",
         '--cpus', @options.fetch('cpus', 1).to_s, '--no-healthcheck',
         *init_options, *security_options, *pairs('--label', @definition.labels), *scalar_options,
         *pairs('--env', @options.fetch('environment', {}).merge(@options.fetch('runtime_environment', {}))),
         *pairs('--sysctl', @options.fetch('sysctls', {})),
         *@options.fetch('mounts', []).flat_map { |mount| ['--mount', mount] },
         *@options.fetch('ports', []).flat_map { |port| ['--publish', port] },
         @options.fetch('image'), *@options.fetch('command', [])]
      end

      private

      def security_options
        values = { 'cap_drop' => '--cap-drop', 'cap_add' => '--cap-add', 'devices' => '--device',
                   'security_options' => '--security-opt' }
        [*(@options['read_only'] ? ['--read-only'] : []),
         *values.flat_map { |key, flag| @options.fetch(key, []).flat_map { |value| [flag, value] } }]
      end

      def init_options
        return ['--init'] if @options['init'] == 'process'
        return [] unless @options['init'] == 'systemd'

        ['--systemd=always', '--cgroupns=private', '--tmpfs', '/run', '--tmpfs', '/tmp']
      end

      def scalar_options
        SCALARS.flat_map { |key, option| @options[key] ? [option, @options[key]] : [] }
      end

      def pairs(option, values)
        values.flat_map { |key, value| [option, "#{key}=#{value}"] }
      end
    end
  end
end
