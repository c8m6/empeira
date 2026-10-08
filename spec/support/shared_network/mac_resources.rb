# frozen_string_literal: true

require_relative 'routes'

module SharedNetworkProof
  module MacResources
    private

    def journal
      file = File.join(directory, 'ownership.json')
      File.write("#{file}.new", JSON.pretty_generate(token: token, runtime: @runtime.class.name, intents: @intents),
                 mode: 'w', perm: 0o600)
      File.rename("#{file}.new", file)
    end

    def intent(kind, name)
      @intents.fetch(kind)[name] = nil
      journal
    end

    def record(kind, name, id)
      @intents.fetch(kind)[name] = id
      journal
    end

    def create_network(name = @network, subnet = "#{prefix}.0/24", interface = bridge)
      reject_overlap(subnet)
      intent('networks', name)
      @runtime.run('network', 'create', '--internal', '--subnet', subnet,
                   '--label', "#{Ownership::LABEL}=#{token}", *@runtime.network_options(interface), name)
      record_network(name)
    end

    def record_network(name)
      observed = JSON.parse(@runtime.run('network', 'inspect', name)).first
      id = @runtime.network_id(observed)
      Ownership.verify!(observed, id: id, token: token)
      record('networks', name, id)
      raise Failure, 'Expected internal bridge' unless @runtime.internal?(observed)
    end

    def reject_overlap(candidate)
      names = @runtime.run('network', 'ls', '--format', '{{.Name}}').lines.map(&:strip)
      names.each do |name|
        info = JSON.parse(@runtime.run('network', 'inspect', name)).first
        subnets = info['subnets'] || info.dig('IPAM', 'Config') || []
        subnets.each do |subnet|
          Routes.reject_overlap!([{ 'dst' => subnet['subnet'] || subnet['Subnet'] }], candidate)
        end
      end
    end

    def create_container(name, ip, security, image, args, **options)
      full_name = "#{@network}-#{name}"
      intent('containers', full_name)
      options = container_options(full_name, ip, options)
      id = @runtime.run('create', *options, *security, image, *args).strip
      record('containers', full_name, id)
      containers[name] = id
      verify_container(id)
      @runtime.run('start', id)
    end

    def container_options(full_name, ip, options)
      network = options.fetch(:network, @network)
      mac = "02:#{SecureRandom.hex(5).scan(/../).join(':')}"
      ['--name', full_name, '--label', "#{Ownership::LABEL}=#{token}",
       '--network', network, '--ip', ip, '--mac-address', mac,
       '--read-only', '--tmpfs', '/tmp', '--sysctl', 'net.ipv6.conf.all.disable_ipv6=1',
       '--sysctl', 'net.ipv6.conf.default.disable_ipv6=1',
       '--sysctl', 'net.ipv4.ip_forward=0']
    end

    def verify_container(id)
      observed = JSON.parse(@runtime.run('inspect', id)).first
      Ownership.verify!(observed, id: id, token: token)
      raise Failure, 'Application port publication forbidden' unless observed.dig('HostConfig',
                                                                                  'PortBindings').to_h.empty?

      observed
    end

    def remove_owned(kind, name)
      prefix, list, flags = resource_commands(kind)
      # Even a failed create can have taken effect: inspect the recorded intent first.
      names = @runtime.run(*prefix, *list)
      return unless names.lines.map(&:strip).include?(name)

      id = owned_id(kind, name, prefix)
      @runtime.run(*prefix, 'rm', *flags, id)
      @intents.fetch(kind).delete(name)
      journal
    end

    def owned_id(kind, name, prefix)
      observed = JSON.parse(@runtime.run(*prefix, 'inspect', name)).first
      id = @intents.fetch(kind).fetch(name) || observed['Id'] || observed.fetch('id')
      Ownership.verify!(observed, id: id, token: token)
      id
    end

    def resource_commands(kind)
      { 'networks' => [['network'], ['ls', '--format', '{{.Name}}'], []],
        'containers' => [[], ['ps', '-a', '--format', '{{.Names}}'], ['--force']] }.fetch(kind)
    end
  end
end
