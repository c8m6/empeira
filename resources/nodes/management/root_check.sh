# Verify root metadata without logging password hashes or relying on regular login policy.
verify_root() {
  test "$(id -u)" = 0 || fail 'management session is not root'
  root_account=$(getent passwd root) || fail 'missing root account'
  test "$(printf '%s\n' "$root_account" | cut -d : -f 3)" = 0 || fail 'root UID changed'
  root_shell=$(printf '%s\n' "$root_account" | cut -d : -f 7)
  case "$root_shell" in ''|*/nologin|*/false) fail 'root shell prevents management login' ;; esac
  test -x "$root_shell" || fail 'root shell is unavailable'
  root_shadow=$(getent shadow root) || fail 'cannot verify root key authentication'
  root_password=$(printf '%s\n' "$root_shadow" | cut -d : -f 2)
  case "$root_password" in ''|\!*) fail 'root account prevents public-key login' ;; esac
  unset root_shadow root_password root_account
}
verify_root
