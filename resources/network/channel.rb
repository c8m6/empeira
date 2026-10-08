# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only

require_relative '../../lib/empeira'

path = Pathname(ARGV.fetch(0))
metadata = path.lstat
unless metadata.file? && metadata.uid == Process.uid && metadata.mode.nobits?(0o077)
  abort 'Unsafe peer channel configuration'
end
Process.daemon(false, false)
begin
  Empeira::Network::Peer::ChannelServer.new(path).run
rescue StandardError => e
  File.open(path.dirname.join('channel.log'), 'a', 0o600) { |log| log.puts("#{e.class}: #{e.message}") }
  exit 1
end
