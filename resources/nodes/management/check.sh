#!/bin/sh
# Fail closed; never repair a changed account, unit, daemon or authentication policy.
set -eu
fail() { echo "Management SSH verification failed: $1; inspect node shell and serial logs" >&2; exit 1; }
owned() {
  test ! -L "$1" && test -f "$1" || fail "unsafe $1"
  test "$(stat -c '%u:%h:%a' "$1")" = "0:1:$2" || fail "ownership or permissions of $1"
}
for directory in /etc/empeira /etc/empeira/management; do
  test ! -L "$directory" && test -d "$directory" || fail "unsafe $directory"
  test "$(stat -c '%u:%a' "$directory")" = '0:755' || fail "ownership or permissions of $directory"
done
owned /etc/empeira/management/sshd_config 644
owned /etc/systemd/system/empeira-management-ssh.service 644
owned /etc/empeira/management/authorized_keys 600
owned /etc/empeira/management/ssh_host_ed25519_key 600
owned /usr/local/libexec/empeira-management-check 755
test "$(sha256sum /etc/empeira/management/sshd_config | cut -d ' ' -f 1)" = '@CONFIG_SHA@' || fail 'changed management configuration'
test "$(sha256sum /etc/systemd/system/empeira-management-ssh.service | cut -d ' ' -f 1)" = '@UNIT_SHA@' || fail 'changed management unit'
test "$(sha256sum /etc/empeira/management/authorized_keys | cut -d ' ' -f 1)" = '@AUTHORIZED_SHA@' || fail 'changed management authorized keys'
@ACCOUNT_CHECK@
test ! -L /etc/empeira/management/uploads && test -d /etc/empeira/management/uploads || fail 'unsafe upload directory'
test "$(stat -c '%u:%g:%a' /etc/empeira/management/uploads)" = '0:0:700' || fail 'upload directory ownership or permissions'
systemctl is-active --quiet empeira-management-ssh.service || fail 'management daemon is inactive'
systemctl is-enabled --quiet empeira-management-ssh.service || fail 'management daemon is disabled'
/usr/sbin/sshd -t -f /etc/empeira/management/sshd_config || fail 'invalid management SSH configuration'
owned /usr/local/libexec/empeira-management-policy 755
test "$(sha256sum /usr/local/libexec/empeira-management-policy | cut -d ' ' -f 1)" = '@POLICY_SHA@' || fail 'changed management policy verifier'
/usr/local/libexec/empeira-management-policy
