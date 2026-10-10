# Verify regular system SSH account metadata without exposing shadow contents or assigning a fixed UID/GID.
verify_account() {
  empeira_account=$(getent passwd empeira) || fail 'missing system SSH account empeira'
  empeira_uid=$(printf '%s\n' "$empeira_account" | cut -d : -f 3)
  empeira_gid=$(printf '%s\n' "$empeira_account" | cut -d : -f 4)
  empeira_home=$(printf '%s\n' "$empeira_account" | cut -d : -f 6)
  empeira_shell=$(printf '%s\n' "$empeira_account" | cut -d : -f 7)
  empeira_uid_min=$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ { print $2 }' /etc/login.defs)
  for empeira_number in "$empeira_uid" "$empeira_gid" "$empeira_uid_min"; do
    case "$empeira_number" in ''|*[!0-9]*) fail 'unverifiable system SSH UID/GID range' ;; esac
  done
  test "$empeira_uid" -gt 0 && test "$empeira_uid" -lt "$empeira_uid_min" || fail 'expected a dedicated system UID'
  test "$empeira_gid" -gt 0 || fail 'system SSH account must not use the root group'
  test "$empeira_home" = /var/lib/empeira || fail 'changed system SSH home; expected /var/lib/empeira'
  test "$empeira_shell" = /bin/bash && test -x "$empeira_shell" || fail 'changed system SSH shell; expected /bin/bash'
  empeira_shadow=$(getent shadow empeira) || fail 'cannot verify the system SSH password lock'
  empeira_password=$(printf '%s\n' "$empeira_shadow" | cut -d : -f 2)
  case "$empeira_password" in \!*|\**) ;; *) fail 'system SSH password must stay locked' ;; esac
  unset empeira_shadow empeira_password empeira_account
  test ! -L /var/lib/empeira || fail 'system SSH home is a symlink'
  if test "$1" = creating && test ! -e /var/lib/empeira; then return; fi
  test -d /var/lib/empeira || fail 'system SSH home is missing or not a directory'
  test "$(stat -c '%u:%g:%a' /var/lib/empeira)" = "$empeira_uid:$empeira_gid:700" || fail 'system SSH home ownership or permissions changed'
}
