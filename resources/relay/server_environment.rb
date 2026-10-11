# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-only

require 'puppet'

# Read native server settings without selecting an environment.conf override.
Puppet.initialize_settings(ARGV)
Puppet.settings.preferred_run_mode = :server
print Puppet.settings.value(:environment_timeout)
