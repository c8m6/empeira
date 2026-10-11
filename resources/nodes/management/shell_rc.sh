# SPDX-License-Identifier: AGPL-3.0-only
# Preserve interactive configuration and completion without persistent diagnostics history.
if [ -r /etc/bash.bashrc ]; then
  . /etc/bash.bashrc
elif [ -r /etc/bashrc ]; then
  . /etc/bashrc
fi
if [ -r "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
HISTFILE=/dev/null
readonly HISTFILE
