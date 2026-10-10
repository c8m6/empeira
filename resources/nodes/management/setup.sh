#!/bin/sh
# Prepare only the private management daemon on a newly seeded VM.
set -eu
fail() { echo "VM management setup failed: $1; inspect node shell and serial logs" >&2; exit 1; }
@ACCOUNT_SETUP@
@SYSTEM_SETUP@
command -v nsenter >/dev/null || { echo 'Management SSH requires guest util-linux nsenter' >&2; exit 1; }
test -x /usr/sbin/sshd
directory=/etc/empeira/management
test ! -L "$directory"
chown root:root "$directory"
chmod 0755 "$directory"
test ! -e "$directory/uploads" && test ! -L "$directory/uploads" || fail 'preexisting upload directory'
install -d -m 0700 -o root -g root "$directory/uploads"
test ! -e "$directory/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -f "$directory/ssh_host_ed25519_key"
chmod 0600 "$directory/ssh_host_ed25519_key"
@SELINUX_SETUP@
systemctl daemon-reload
systemctl enable --now empeira-management-ssh.service
