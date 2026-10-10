# Keep SELinux enforcing; scope labels to the private management endpoint and files.
if test -e /sys/fs/selinux/enforce; then
  command -v semodule >/dev/null && command -v restorecon >/dev/null || fail 'SELinux management requires guest policycoreutils'
  empeira_modules=$(semodule -lfull) || fail 'cannot verify existing SELinux modules'
  if printf '%s\n' "$empeira_modules" | awk '$2 == "empeira_management" { found=1 } END { exit !found }'; then
    fail 'preexisting empeira_management SELinux module; refusing to replace foreign policy'
  fi
  unset empeira_modules
  semodule -i /etc/empeira/management/empeira_management.cil
  restorecon -R /etc/empeira/management
fi
