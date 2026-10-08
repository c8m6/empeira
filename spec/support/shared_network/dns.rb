# frozen_string_literal: true

module SharedNetworkProof
  module DNS
    IMAGE = Empeira::Images::Configuration.reference(
      Empeira::Configuration::Document.new.read(Empeira::Configuration::Loader::DEFAULTS).dig('images', 'dns')
    ).freeze

    private

    def start_dns
      hosts = addresses.map { |name, ip| "#{ip} #{name}.empeira.internal #{name}" }.join("\n")
      config = ".:53 {\n hosts {\n#{hosts}\n ttl 1\n }\n errors\n}\n"
      file = File.join(directory, 'Corefile')
      File.write(file, config)
      run_container('dns', ['--network', "#{@network}:ip=#{addresses.fetch('dns')}",
                            '--volume', "#{file}:/Corefile:ro,Z"], DNS::IMAGE, ['-conf', '/Corefile'])
    rescue Failure => e
      raise Failure, "CoreDNS startup failed: #{e.message}; #{dns_diagnostics}"
    end

    def wait_dns
      Timeout.timeout(15) do
        loop do
          request('container-a', op: 'dns', target: "#{addresses.fetch('dns')}:53",
                                 name: 'vm-a.empeira.internal', want: addresses.fetch('vm-a'))
          return
        rescue Failure
          sleep 0.2
        end
      end
    rescue Timeout::Error
      raise Failure, "CoreDNS readiness failed; #{dns_diagnostics}"
    end

    def dns_diagnostics
      id = containers['dns']
      return 'container was not created' unless id

      # Select only state/exit code, never the inspect environment or other configuration.
      details = {}
      attempt_diagnostic(details, :state) do
        state = JSON.parse(@commands.podman('inspect', id)).first.fetch('State')
        JSON.generate(state.slice('Status', 'Running', 'ExitCode', 'Error'))
      end
      attempt_diagnostic(details, :logs) { @commands.podman('logs', '--tail', '30', id) }
      details.map { |key, value| "#{key}=#{@commands.diagnostic(value)}" }.join('; ')
    end

    def attempt_diagnostic(details, key)
      details[key] = yield
    rescue Failure => e
      details[key] = "unavailable: #{e.message}"
    end
  end
end
