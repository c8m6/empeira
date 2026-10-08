# frozen_string_literal: true

# OpenSSH ProxyCommand delegates only the byte transport to the central runner.
require_relative '../../../lib/empeira'

runtime, id = ARGV
unless Empeira::Runtime.registry.names.include?(runtime) && id&.match?(/\A[a-f0-9]{12,64}\z/)
  abort 'Invalid managed SSH transport'
end
result = Empeira::Execution::Runner.new.stream(runtime, arguments: [
                                                 'exec', '--interactive', id, '/opt/puppetlabs/puppet/bin/ruby',
                                                 '/usr/local/libexec/empeira-ssh-connect.rb', '22'
                                               ])
exit result.exit_status
