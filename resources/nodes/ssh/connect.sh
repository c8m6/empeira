#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# The native exec target pins the instance even before its agent Ruby is installed.
set -eu
if [ -x /opt/puppetlabs/puppet/bin/ruby ] && [ -r /usr/local/libexec/empeira-ssh-connect.rb ]; then
  exec /opt/puppetlabs/puppet/bin/ruby /usr/local/libexec/empeira-ssh-connect.rb "$1"
fi

# Bash and cat are already part of the supported node shell/image contract.
# Relay binary bytes in both directions and reap both children on either EOF.
exec 3<>"/dev/tcp/127.0.0.1/$1"
exec 4<&0
reader= writer= finished=
relay_parent=$$
cleanup() {
  trap '' USR1
  [ -z "$reader" ] || kill "$reader" 2>/dev/null || :
  [ -z "$writer" ] || kill "$writer" 2>/dev/null || :
  wait 2>/dev/null || :
}
trap cleanup EXIT
# Bash 3.2 defers CHLD traps while waiting for a different child. An explicit
# signal interrupts wait on every supported Bash, including native macOS.
trap 'finished=yes; [ -z "$reader" ] || [ -z "$writer" ] || exit 0' USR1
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
relay() {
  child=
  trap '[ -z "$child" ] || kill "$child" 2>/dev/null || :; wait 2>/dev/null || :' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cat <&0 &
  child=$!
  wait "$child" || :
  child=
  kill -USR1 "$relay_parent" 2>/dev/null || :
}
relay <&3 &
reader=$!
relay <&4 >&3 &
writer=$!
[ -z "$finished" ] || exit 0
wait
