# frozen_string_literal: true

module Empeira
  module Configuration
    # Puppet destinations and source availability share one resolution boundary.
    class HieraMounts
      attr_reader :entries

      def initialize(config:, project:, environment:)
        @project = Pathname(project).realpath
        @environment = environment
        HieraMountSchema.validate!(config.fetch('mounts'))
        @entries = config.fetch('mounts').each_with_index.map { |entry, index| resolve(entry, index) }
        HieraModulepath.new(project: @project, environment: @environment).verify! if entries.any? do |entry|
          entry['type'] == 'module'
        end
      end

      def mounts
        entries.filter_map do |entry|
          next unless entry['status'] == 'available'

          "type=bind,src=#{entry['resolved_source']},dst=#{entry['destination']},readonly"
        end
      end

      def warnings
        entries.filter_map do |entry|
          next if entry['status'] == 'available'

          "Warning: optional Hiera source is unavailable: #{entry['source']}; " \
            "mount #{entry['destination']} skipped (#{entry['reason']})"
        end
      end

      private

      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- Classify source availability without suppressing structural errors.
      def resolve(entry, index)
        target = entry['type'] == 'module' ? "modules/#{entry['name']}" : entry['target']
        validate_destination!(target, index)
        definition = entry.merge('required' => entry.fetch('required', false),
                                 'destination' => "#{environment_root}/#{target}")
        source = Pathname(entry['source']).expand_path(@project).realpath
        unless source.directory? && HieraMountSchema.safe_source?(source.to_s)
          raise ConfigurationError, "hiera.mounts.#{index}.source must resolve to a directory with a safe mount path"
        end
        raise Errno::EACCES unless source.readable? && source.executable?

        definition.merge('resolved_source' => source.to_s, 'status' => 'available')
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => e
        if entry['required']
          raise ConfigurationError, "hiera.mounts.#{index}.source is required but unavailable (#{e.class})",
                cause: nil
        end

        definition.merge('status' => 'skipped',
                         'reason' => e.is_a?(Errno::ENOENT) ? 'missing source' : 'inaccessible source')
      rescue SystemCallError
        raise ConfigurationError, "hiera.mounts.#{index}.source cannot be resolved safely", cause: nil
      end

      def environment_root
        "/etc/puppetlabs/code/environments/#{@environment}"
      end

      def validate_destination!(target, index)
        current = @project
        target.split('/').each do |part|
          current = current.join(part)
          next unless current.exist? || current.symlink?

          resolved = current.realpath
          unless resolved.directory? && resolved.to_s.start_with?("#{@project}/")
            raise ConfigurationError, "hiera.mounts.#{index}.target must remain a directory inside the environment"
          end
        end
      rescue SystemCallError
        raise ConfigurationError, "hiera.mounts.#{index}.target cannot be resolved safely", cause: nil
      end
    end
  end
end
