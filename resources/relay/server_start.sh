#!/bin/sh
set -eu

# Keep the standard Puppet config read-only outside upstream ownership sweeps.
stage_eyaml() {
  for key in private_key public_key; do
    source="/empeira-eyaml/${key}.pkcs7.pem"
    destination="/etc/puppetlabs/puppet/eyaml/${key}.pkcs7.pem"
    mode=0644
    if [ "$key" = private_key ]; then mode=0600; fi
    install -o puppet -g puppet -m "$mode" "$source" "${destination}.pending"
    mv -f "${destination}.pending" "$destination"
  done
}

if [ "${1:-}" = refresh-eyaml ]; then
  stage_eyaml
  exit 0
fi

upstream_entrypoint="$1"
config_destination="$2"
eyaml_mode="$3"
puppetdb_mode="$4"
shift 4
# Use Puppet's own writer: retain every other setting in the configured confdir.
# Environment-variable mappings are only supplementary image startup hints.
confdir="${config_destination%/*}"
/opt/puppetlabs/bin/puppet config set environment_timeout 0 --section server --confdir "$confdir"
test "$(/opt/puppetlabs/bin/puppet config print environment_timeout --section server --confdir "$confdir")" = 0
if [ "$eyaml_mode" = staged ]; then
  stage_eyaml
fi
if [ "$puppetdb_mode" = puppetdb ]; then
  ln -sfn /empeira-server/puppetdb.conf "$config_destination"
fi
exec "$upstream_entrypoint" "$@"
