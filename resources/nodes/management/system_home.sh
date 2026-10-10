# Cloud-init system users deliberately omit ssh_authorized_keys and home creation.
verify_account creating
if test ! -e /var/lib/empeira; then
  install -d -m 0700 -o "$empeira_uid" -g "$empeira_gid" /var/lib/empeira
fi
verify_account verified
test ! -e /var/lib/empeira/.ssh && test ! -L /var/lib/empeira/.ssh || fail 'preexisting system SSH key directory'
install -d -m 0700 -o "$empeira_uid" -g "$empeira_gid" /var/lib/empeira/.ssh
install -m 0600 -o "$empeira_uid" -g "$empeira_gid" /etc/empeira/management/system_authorized_keys /var/lib/empeira/.ssh/authorized_keys
for empeira_profile in .bashrc .bash_profile .profile; do
  if test -f "/etc/skel/$empeira_profile" && test ! -e "/var/lib/empeira/$empeira_profile"; then
    test ! -L "/etc/skel/$empeira_profile" && test ! -L "/var/lib/empeira/$empeira_profile" || fail 'unsafe shell initialization path'
    install -m 0600 -o "$empeira_uid" -g "$empeira_gid" "/etc/skel/$empeira_profile" "/var/lib/empeira/$empeira_profile"
  fi
done
