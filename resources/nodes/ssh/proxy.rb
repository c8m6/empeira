# frozen_string_literal: true

# OpenSSH ProxyCommand delegates only the byte transport to the central runner.
require_relative '../../../lib/empeira'

runtime, id, port = ARGV
port ||= '22'
unless Empeira::Runtime.registry.names.include?(runtime) && id&.match?(/\A[a-f0-9]{12,64}\z/) &&
       port.match?(/\A[0-9]{1,5}\z/) && port.to_i.between?(1, 65_535) && ARGV.size <= 3
  abort 'Invalid managed SSH transport'
end
result = Empeira::Execution::Runner.new.stream(runtime, arguments: [
                                                 'exec', '--interactive', id, '/opt/puppetlabs/puppet/bin/ruby',
                                                 '/usr/local/libexec/empeira-ssh-connect.rb', port
                                               ])
exit result.exit_status
