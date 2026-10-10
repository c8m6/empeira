# OpenSSH without PAM rejects Linux's ! account lock even for public keys.
# Replace only a locked root password with an impossible hash; preserve console passwords.
root_shadow=$(getent shadow root) || fail 'cannot inspect root key authentication'
root_password=$(printf '%s\n' "$root_shadow" | cut -d : -f 2)
case "$root_password" in
  \!*) usermod --password '*' root || fail 'cannot prepare root key authentication' ;;
  '') fail 'empty root password is unsafe' ;;
esac
unset root_shadow root_password
