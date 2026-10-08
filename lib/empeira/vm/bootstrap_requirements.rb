# frozen_string_literal: true

require 'uri'

module Empeira
  module VM
    # Reviewed image metadata determines installation needs before any download.
    class BootstrapRequirements
      attr_reader :repository, :agent, :guest

      def initialize(context:, os:, version:, agent_required: nil, distribution_required: false,
                     architecture: context.platform.architecture)
        config = context.configuration
        @os = os
        @architecture = architecture.to_s
        @guest = config.fetch('bootstrap').fetch('guests').fetch(os).fetch(version)
        @agent_required = agent_required.nil? ? !guest.fetch('agent_preinstalled') : agent_required
        @distribution_required = distribution_required || @agent_required
        return unless @agent_required || @distribution_required

        load_agent(config, os, version) if @agent_required
      rescue KeyError
        raise ConfigurationError,
              'No reviewed agent source exists for this guest'
      end

      def required?
        @agent_required
      end

      def destinations
        distribution_destinations = @distribution_required ? guest_destinations : []
        [*agent_destinations, *distribution_destinations].uniq
      end

      def report
        "Managed bootstrap destinations: #{destinations.join(', ')}"
      end

      def rpm_options
        return [] unless %w[rocky almalinux].include?(@os)

        architecture = ImageSource::ARCHITECTURES.fetch(@architecture)
        base = guest.fetch('baseurl')
        { 'baseos' => 'BaseOS', 'appstream' => 'AppStream', 'extras' => 'extras' }.flat_map do |id, directory|
          ["--setopt=#{id}.mirrorlist=", "--setopt=#{id}.metalink=",
           "--setopt=#{id}.baseurl=#{base}/#{directory}/#{architecture}/os/"]
        end
      end

      private

      def agent_destinations
        return [] unless repository

        urls = [repository.fetch('url'), repository.dig('release', 'url'), repository.dig('key', 'url')].compact
        extras = repository.fetch('destinations', [])
        [*urls.map { |url| URI(url).host }, *extras]
      end

      def guest_destinations
        destinations = guest.fetch('destinations')
        return destinations unless @os == 'ubuntu'

        irrelevant = @architecture == 'arm64' ? %w[archive.ubuntu.com security.ubuntu.com] : ['ports.ubuntu.com']
        destinations - irrelevant
      end

      def load_agent(config, os, version)
        @agent = config.fetch('agent')
        install = @agent.fetch('install')
        Node::AgentRepository.credentials
        family = Node::PackageBootstrap::FAMILIES.fetch(os)
        key = family == 'debian' ? "#{os}#{version}" : "el#{version}"
        if install.fetch('method') == 'package'
          @repository = install.fetch('packages').fetch(key).fetch(@architecture)
        else
          manager = family == 'debian' ? 'apt' : 'dnf'
          @repository = install.fetch(manager).fetch(key) do
            install.fetch('repositories').fetch(key)
          end
        end
      end
    end
  end
end
