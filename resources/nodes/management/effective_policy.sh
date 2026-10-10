#!/bin/sh
# Validate effective OpenSSH policy before startup and every managed command.
set -eu
fail() { echo "Management SSH effective policy failed: $1" >&2; exit 1; }
policy=$(/usr/sbin/sshd -T -f /etc/empeira/management/sshd_config) || fail 'sshd -T failed'
require() { printf '%s\n' "$policy" | grep -Fqx -- "$1" || fail "$1"; }
require 'allowusers root'
require 'authenticationmethods publickey'
require 'pubkeyauthentication yes'
require 'passwordauthentication no'
require 'kbdinteractiveauthentication no'
require 'usepam no'
require 'strictmodes yes'
require 'authorizedkeysfile /etc/empeira/management/authorized_keys'
require 'authorizedkeyscommand none'
require 'trustedusercakeys none'
require 'hostkey /etc/empeira/management/ssh_host_ed25519_key'
require 'listenaddress 10.0.2.15:22222'
require 'allowagentforwarding no'
require 'x11forwarding no'
require 'permituserrc no'
require 'permituserenvironment no'
require 'allowtcpforwarding local'
require 'permitopen @PEER@:*'
require 'allowstreamlocalforwarding no'
require 'gatewayports no'
# OpenSSH normalizes the prohibit-password spelling to without-password.
printf '%s\n' "$policy" | grep -Eq '^permitrootlogin (prohibit-password|without-password)$' || fail 'root public-key policy'
