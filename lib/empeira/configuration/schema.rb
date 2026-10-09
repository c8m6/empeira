# frozen_string_literal: true

require 'ipaddr'

module Empeira
  module Configuration
    # Keep the public schema and its fragment/effective validation in one boundary.
    # rubocop:disable-next Metrics/ClassLength
    class Schema
      CONTAINER_ENGINES = Runtime.registry.names
      DNS_LABEL = '[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
      DNS_NAME = /\A#{DNS_LABEL}(?:\.#{DNS_LABEL})*\.?\z/
      RULES = {
        'version' => :version,
        'requirements' => { 'empeira' => :requirement },
        'runtime' => { 'container_engine' => :engine },
        'modules' => { 'path' => :module_path },
        'server' => { 'runtime' => :server_runtime, 'mounts' => :server_mounts,
                      'environment' => :environment,
                      'memory' => :positive_integer, 'cpus' => :positive_integer, 'timeout' => :positive_integer },
        'puppetdb' => { 'enabled' => :boolean, 'memory' => :positive_integer, 'runtime' => :puppetdb_runtime },
        'network' => { 'egress' => :network_egress, 'redirects' => :network_redirects },
        'proxy' => { 'enabled' => :boolean, 'global' => :allowlist, 'rules' => :proxy_rules },
        'vm' => { 'interfaces' => :vm_interfaces, 'console' => { 'root_password' => :optional_string } },
        'dns' => { 'upstream' => { 'mode' => :dns_mode, 'servers' => :dns_servers },
                   'additional_resolver' => :additional_resolver, 'rewrites' => :dns_rewrites },
        'node_defaults' => { 'init' => :node_init, 'os' => :optional_string, 'version' => :optional_string,
                             'memory' => :positive_integer, 'cpus' => :positive_integer },
        'mocks' => { 'commands' => :command_mocks },
        'hiera' => { 'mounts' => :hiera_mounts },
        'eyaml' => { 'enabled' => :boolean, 'private_key' => :optional_string, 'public_key' => :optional_string },
        'images' => { 'registry' => :registry, 'network_adapter_builder' => :image,
                      'server' => :image, 'puppetdb' => :image, 'postgres' => :image,
                      'dns' => :image, 'proxy' => :image, 'direct_egress' => :image,
                      'relay' => :image, 'r10k' => :image,
                      'nodes' => :node_images },
        'agent' => :agent,
        'bootstrap' => { 'enabled' => :boolean, 'scripts' => :bootstrap_scripts,
                         'packages' => :bootstrap_packages, 'guests' => :bootstrap_guests },
        'browser' => { 'start_url' => :browser_start_url,
                       'image' => { 'repository' => :image_repository, 'tag' => :image_tag } },
        'containers' => { 'additional' => :additional_services }
      }.tap { |rules| Immutable.deep_freeze(rules) }

      CHECKS = {
        registry: [Images::Reference.method(:registry?),
                   'must be null or a registry host with a dot, port or localhost (no scheme or path)'],
        browser_start_url: [->(v) { v.is_a?(String) && !v.strip.empty? && !v.match?(/\p{Cc}/) },
                            'must be a nonempty string without control characters'],
        module_path: [->(v) { v.is_a?(String) && !v.strip.empty? && !v.match?(/[\x00-\x1f\x7f,]/) },
                      'must be a nonempty directory path without commas or control characters'],
        image_repository: [->(v) { v.is_a?(String) && v.match?(Images::Configuration::REPOSITORY) },
                           'must be an image repository'],
        image_tag: [->(v) { v.is_a?(String) && v.match?(Images::Configuration::TAG) }, 'must be an image tag'],
        node_init: [->(v) { %w[process systemd].include?(v) }, 'must be process or systemd'],
        dns_mode: [->(v) { %w[host explicit].include?(v) }, 'must be host or explicit'],
        dns_servers: [lambda do |v|
          v.is_a?(Array) && v.all? do |address|
            address.is_a?(String) && IPAddr.new(address).ipv4? && IPAddr.new(address).to_s == address
          end
        rescue IPAddr::InvalidAddressError
          false
        end, 'must contain canonical IPv4 DNS resolver addresses; IPv6 is not supported'],
        additional_resolver: [lambda do |v|
          v.nil? || (v.is_a?(String) && v.size <= 253 &&
            ((v.match?(DNS_NAME) && !v.match?(/\A[\d.]+\z/)) || (IPAddr.new(v).ipv4? && IPAddr.new(v).to_s == v)))
        rescue IPAddr::InvalidAddressError
          false
        end, 'must be null, a DNS name, or a canonical IPv4 address; IPv6 is not supported'],
        environment: [lambda { |v|
          v.is_a?(String) && v.match?(/\A[a-z][a-z0-9_]*\z/)
        }, 'must be a Puppet environment name'],
        allowlist: [->(v) { v.is_a?(Array) && v.all? { |d| Network::ProxyPolicy.valid_domain?(d) } },
                    'must contain lowercase DNS domains or *.domain entries (no URLs, IPs or whitespace)'],
        bootstrap_scripts: [lambda { |v|
          v.is_a?(Array) && v.all? do |path|
            path.is_a?(String) && !path.empty? && !path.start_with?('/') &&
              !path.include?("\0") && !path.split('/').intersect?(%w[. ..])
          end
        }, 'must list relative local script paths within the project'],
        version: [->(v) { v.is_a?(Integer) && v == 1 }, 'must be the supported schema version 1'],
        engine: [->(v) { CONTAINER_ENGINES.include?(v) }, "must be one of: #{CONTAINER_ENGINES.join(', ')}"],
        boolean: [->(v) { [true, false].include?(v) }, 'must be a boolean'],
        optional_string: [lambda { |v|
          v.nil? || (v.is_a?(String) && !v.strip.empty? && v == v.strip)
        }, 'must be a non-empty string or null (without surrounding whitespace)'],
        positive_integer: [->(v) { v.is_a?(Integer) && v.positive? }, 'must be a positive integer']
      }.tap { |checks| Immutable.deep_freeze(checks) }

      def initialize(cross_field_rules: [])
        @cross_field_rules = cross_field_rules.dup.freeze
      end

      def validate_effective!(data)
        validate_fragment!(data)
        require_keys!(data, RULES, [])
        CommandMocks.validate!(data.dig('mocks', 'commands'), 'mocks.commands', effective: true)
        validate_operational!(data)
        @cross_field_rules.each { |rule| rule.call(data) }
        data
      end

      def validate_fragment!(data)
        validate_mapping!(data, RULES, [])
        data
      end

      private

      def validate_operational!(data)
        validate_images!(data.fetch('images'))
        NodeImages.effective!(data.fetch('images'))
        Server::Runtime.resolve(data)
        Server::PuppetDBRuntime.resolve(data)
        validate_dns!(data.dig('dns', 'upstream'))
        validate_bootstrap!(data.fetch('bootstrap'))
        AgentSchema.effective!(data.fetch('agent'))
      end

      def validate_bootstrap!(bootstrap)
        BootstrapGuests.effective!(bootstrap.fetch('guests'))
        Node::PackageBootstrap.validate!(bootstrap.fetch('packages'), 'bootstrap.packages', effective: true)
        return if bootstrap.fetch('enabled') || bootstrap.fetch('scripts').empty?

        raise ConfigurationError, 'bootstrap.scripts requires bootstrap.enabled=true'
      end

      def validate_dns!(upstream)
        return unless (upstream['mode'] == 'explicit') == upstream['servers'].empty?

        raise ConfigurationError, 'dns.upstream.servers must be nonempty in explicit mode and empty in host mode'
      end

      def validate_images!(images)
        %w[server puppetdb postgres dns proxy direct_egress relay r10k network_adapter_builder].each do |key|
          ImageSchema.validate!(images[key], "images.#{key}", effective: true)
        end
      end

      def require_keys!(data, rules, path)
        rules.each do |key, rule|
          child_path = path + [key]
          raise ConfigurationError, "#{child_path.join('.')} is required" unless data.key?(key)

          require_keys!(data.fetch(key), rule, child_path) if rule.is_a?(Hash)
        end
      end

      def validate_mapping!(data, rules, path)
        location = path.empty? ? '$' : path.join('.')
        raise ConfigurationError, "#{location} must be a mapping" unless data.is_a?(Hash)

        data.each do |key, value|
          # Do not echo untrusted keys: they may contain credentials or YAML values.
          raise ConfigurationError, "#{location} contains a non-string key" unless key.is_a?(String)

          child_path = path + [key]
          unless rules.key?(key)
            if child_path == %w[network internet]
              validate_value!(value, :boolean, child_path)
              next
            end

            raise ConfigurationError,
                  "#{child_path.join('.')} is not a supported configuration key"
          end

          validate_value!(value, rules.fetch(key), child_path)
        end
      end

      def structured_validator(rule)
        { additional_services: AdditionalServices.method(:validate!), proxy_rules: Network::HostPolicy.method(:validate!),
          hiera_mounts: HieraMountSchema.method(:validate!), command_mocks: CommandMocks.method(:validate!),
          server_mounts: ServerMounts.method(:validate!), dns_rewrites: DNSRewrites.method(:validate!),
          image: ImageSchema.method(:validate!),
          node_images: NodeImages.method(:nodes),
          agent: AgentSchema.method(:validate!), bootstrap_guests: BootstrapGuests.method(:validate!),
          bootstrap_packages: Node::PackageBootstrap.method(:validate!),
          network_egress: Network::DirectEgress.method(:validate!),
          network_redirects: NetworkRedirects.method(:validate!),
          vm_interfaces: VMInterfaces.method(:validate!),
          server_runtime: Server::Runtime.method(:validate!),
          puppetdb_runtime: Server::PuppetDBRuntime.method(:validate!) }[rule]
      end

      def validate_value!(value, rule, path)
        return validate_mapping!(value, rule, path) if rule.is_a?(Hash)
        return VersionRequirement.parse(value) if rule == :requirement

        validator = structured_validator(rule)
        return validator.call(value, path.join('.')) if validator

        check, message = CHECKS.fetch(rule)
        raise ConfigurationError, "#{path.join('.')} #{message}" unless check.call(value)
      end
    end
  end
end
