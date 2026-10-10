#!/bin/sh
# Seed management and the ordinary SSH account once, before project bootstrap.
set -eu
fail() { echo "VM management setup failed: $1; inspect node shell and serial logs" >&2; exit 1; }
interpreter=
for candidate in /usr/bin/python3 /usr/libexec/platform-python; do
  if test -x "$candidate" && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 5))'; then
    interpreter="$candidate"
    break
  fi
done
test -n "$interpreter" || fail 'the selected cloud image requires Python 3 before bootstrap'
test ! -e /usr/local/libexec/empeira-management-python && test ! -L /usr/local/libexec/empeira-management-python || fail 'preexisting management interpreter'
ln -s "$interpreter" /usr/local/libexec/empeira-management-python
@SYSTEM_SETUP@
if test -e /sys/fs/selinux/enforce; then
  restorecon -R /usr/local/libexec/empeira-management-agent /etc/empeira/management /var/lib/empeira
fi
systemctl daemon-reload
systemctl enable --now empeira-management.service
