# Minimal Empeira addon

This AGPL-3.0-only fixture is also a complete standalone addon example. Copy this
directory into its own Git repository, preserve the executable bit on
`bin/example`, commit it and configure its Git URL and ref under `addons` in your
control repository's existing `.empeira.yaml`.

Run `empeira addon example echo input.yaml output.yaml`. The example prints its
arguments; it does not convert or modify files. `echo`, `directory`, `choose` and
`plain` demonstrate declarative completion. Ruby must be on `PATH`; any language
with an executable entrypoint can replace it. Empeira installs no dependencies.

See [the addon contract](../../../docs/addons.md) for the complete schema,
environment API and security model.
