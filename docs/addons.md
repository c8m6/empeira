# Standalone Git addons (API 1)

Empeira remains a local Puppet/OpenVox test environment. Addons expose independent
helper programs through its CLI, for example a converter, data synchronization
tool or Git hook installer. Core does not import their Ruby classes or know their
functionality. There is no plugin runtime, registry, package manager, dependency
installer or lifecycle hook. No production helper tools ship with Empeira.

## Companion addons

These independently maintained addons can be installed through Empeira but are
not bundled with the core application. See each repository for installation and
usage details.

| Addon | Description |
| --- | --- |
| [Convert](https://github.com/c8m6/empeira-addon-convert) | Convert YAML, JSON, XML, Java Properties and Puppet hashes, and generate EPP templates with typed defaults. |
| [Pre-Commit](https://github.com/c8m6/empeira-addon-pre-commit) | Manage Git pre-commit hooks for control and Hiera repositories using locally built Docker or Podman images. |
| [Sync](https://github.com/c8m6/empeira-addon-sync) | Synchronize configured files and directories with host rsync, using source and destination to define direction. |

## Configuration and commands

Declare addons in the existing effective configuration, normally the control
repository's `.empeira.yaml`:

```yaml
addons:
  converter:
    git: https://github.com/example/empeira-converter.git
    ref: v1.2.0
    config:
      output_format: yaml
      paths: [data, defaults]
  git-hooks:
    git: git@example.org:team/empeira-git-hooks.git
    ref: main
```

Each entry requires `git` and `ref` and may optionally contain `config`, a mapping
of addon-specific settings. The addon itself interprets those settings; the
`converter` example above is illustrative, not a built-in Empeira option.
Config keys use lowercase letters, digits and underscores, starting with a letter;
values may be nested mappings, arrays or simple YAML scalars. Do not put secrets
in addon config: it is visible in project configuration and the addon's environment.
`git` and `ref` must be nonempty strings after merging. Names start with a lowercase letter and contain lowercase letters,
digits, underscores or hyphens, up to 63 characters. Built-in defaults contain
`addons: {}`. Mappings deep-merge and project overrides may replace just a ref.
Normal defaults/project/user/CLI precedence and validation remain in force.
The existing user preference file does **not** accept addon definitions. There is
no additional user configuration file and no executable or completion settings
in Empeira configuration.

```console
empeira addons list
empeira addons info converter
empeira addons sync
empeira addons update
empeira addon converter convert input.xml output.json
```

`addons list` inspects configured names and reports missing, installed or invalid
local installations. `addons info NAME` shows the source, configured ref, resolved
commit, absolute installation path and complete validated manifest. Neither
command downloads anything. Invalid installations are reported explicitly.

`addons sync` and `addons update` synchronize all configured sources and refs.
Both use the same explicit refresh semantics as `update modules`: branches and
moved tags follow the fetched source; a commit reference selects that commit.
They attempt every configured addon and return failure if any cannot be installed.
Already published versions survive failed updates. They need host Git and network
access to the configured sources, but no container engine, server, node, network,
proxy or infrastructure inventory.

`addon NAME ...` runs exactly one executable. Everything after NAME, including
`--help`, `--version`, `--`, empty arguments and shell metacharacters, is passed
unchanged. Core options belong **before** `addon`, for example
`empeira --container-engine docker addon example ...`. Manifest commands describe
completion; they do not restrict the executable's argument parser or validate its
arguments. Singular `addon` executes; plural `addons` manages.

Direct execution automatically installs a missing ref. Subsequent executions use
the locally installed ref without network freshness checks. `up` also installs
missing refs, after the Puppet infrastructure is ready. An addon failure makes
`up` return failure with a separate addon diagnostic; the successfully prepared
Puppet infrastructure remains usable. Invalid addon manifests do not affect Core
commands. Invalid Empeira configuration still follows normal configuration errors.
`update images`, `update modules` and the currently unavailable `update all` retain
their existing behavior; addon updates use `addons update`.

## Git references and storage

Empeira reuses the Puppetfile host Git acquisition boundary, including native
SSH configuration, agents, HTTPS credential helpers and sanitized Git diagnostics.
Sources support HTTP(S), SSH URLs and SSH scp syntax. Do not embed HTTP credentials,
URL query strings or fragments; authentication belongs to host Git. Local fixture
servers are used in tests, without external Git services.

`ref` uses the Puppetfile/r10k native Git resolution, `ref^{commit}`: branch, tag,
full or unambiguous abbreviated commit, or `HEAD`. It is not a semantic version
constraint. Unknown refs fail. API 1 requires an explicit ref (`HEAD` is the
explicit equivalent of Puppetfile's default). It does not support Forge versions
or Puppetfile Ruby symbols such as `:control_branch`.

Data lives under `~/.empeira/addons/`, resolved through the existing platform home
abstraction on Linux, macOS and WSL2. Each source has a SHA-256 namespace containing
a bare host mirror, immutable commit directories, hashed reference pointers and a
stable lock file. Equal source strings and commits can be reused across names,
refs and workspaces. Different URLs never collide simply because their addon names
match. Different versions remain available in parallel. No cache eviction is
automatic; do not remove a cache while an addon or synchronization is using it.

Acquisition and publication use an exclusive per-source lock. New mirrors and
revisions are staged privately, checked and atomically renamed. A reference is
published only after manifest and executable validation. Interrupted staging
directories are never considered installed. The control repository is not used as
an installation destination and its tracked files are not modified.
If the configured user home or a cache symlink would put the cache inside the
control repository, installation is rejected before writing there.

Snapshots are materialized by native Git with a disposable index, without a `.git`
working directory. Local checkout ignores inherited Git configuration and disables
hooks, so filters, submodules, addon entrypoints and install scripts are not run.
Tracked files keep their Git content and executable bits. Addons must ship
everything needed for execution or document prerequisites the user installs
separately.

## Manifest contract

Every addon repository has exactly one root-level `empeira-addon.yaml` and one
executable entrypoint:

```text
empeira-addon-example/
├── empeira-addon.yaml
├── bin/
│   └── example
└── README.md
```

```yaml
schema: 1
description: Convert configuration files
executable: bin/example
commands:
  convert:
    description: Convert a file
    arguments:
      - name: input
        completion: file
      - name: output
        completion: file
    options:
      --format:
        description: Output format
        completion: enum
        values: [yaml, text]
      --input:
        completion: file
      --directory:
        completion: directory
      --verbose:
        completion: none
  validate:
    description: Validate input
    arguments:
      - name: input
        completion: file
```

Required root fields are `schema` (integer 1), `description`, `executable` and
`commands` (a mapping, possibly empty). Every command requires a description;
`arguments` (ordered array) and `options` (mapping) are optional. Arguments require
`name` and `completion`. Option names are explicit `-x` or `--long-name` spellings,
with optional descriptions. An option has one value when its completion is `file`,
`directory` or `enum`; `none` declares a flag without a value. To provide short and
long forms, declare each spelling. `enum` requires a nonempty string list `values`;
other types must not have `values`. `none` on an argument disables its completion.
Names and descriptions cannot contain control characters. Unknown fields, YAML
object tags, aliases, duplicate keys and unsupported schema versions are rejected.

There is no nested command framework, dynamic completion, option bundling or
variadic argument schema. The program may implement its own richer CLI; Empeira
offers completion only for the declared interface.

The entrypoint must be a regular executable inside the addon directory. Absolute
paths, `.`/`..` path components, and symlinks escaping that directory are rejected,
including an escaping manifest symlink. Keep the executable bit in Git. Scripts
need a shebang naming an installed interpreter; native binaries must be compatible
with the host. Empeira does not invoke a shell command string or interpolate argv.

## Environment API

Configuration is freshly loaded and merged for every invocation. Empeira exports
its approved fields as `EMPEIRA_CONFIG_*`, without JSON export or temporary
configuration files. Keys become uppercase, with punctuation replaced by `_`.

| Value | Export |
| --- | --- |
| String | Original value, including an empty string |
| Integer/float | String representation |
| Boolean | `true` / `false` |
| Mapping | Recursively flattened keys |
| Array | `_COUNT` and zero-based indexed elements |
| Empty array | `_COUNT=0` |
| Null | No variable |

Array elements can be mappings, arrays or scalars. For example:

```yaml
proxy:
  enabled: true
  global: [forge.puppet.com, github.com]
server:
  mounts:
    - source: /home/user/data
      target: /mnt/data
      readonly: true
```

produces `EMPEIRA_CONFIG_PROXY_ENABLED=true`,
`EMPEIRA_CONFIG_PROXY_GLOBAL_COUNT=2`,
`EMPEIRA_CONFIG_PROXY_GLOBAL_0=forge.puppet.com`,
`EMPEIRA_CONFIG_PROXY_GLOBAL_1=github.com`,
`EMPEIRA_CONFIG_SERVER_MOUNTS_COUNT=1`, and the variables
`EMPEIRA_CONFIG_SERVER_MOUNTS_0_SOURCE`, `_TARGET`, `_READONLY`.

### Per-addon configuration

Only the selected addon's `config` mapping is additionally exported as
`EMPEIRA_ADDON_CONFIG_*`. It uses the same flattening rules as the effective
configuration above. For the example, `converter` receives:

```text
EMPEIRA_ADDON_CONFIG_OUTPUT_FORMAT=yaml
EMPEIRA_ADDON_CONFIG_PATHS_COUNT=2
EMPEIRA_ADDON_CONFIG_PATHS_0=data
EMPEIRA_ADDON_CONFIG_PATHS_1=defaults
```

Other addons' `config` values are **not** included in the general
`EMPEIRA_CONFIG_*` export or the selected addon's export. The optional
`config` mapping deep-merges like other project mappings; arrays replace.
No new addon API version, configuration file or install hook is needed.

Runtime context is separate:

| Variable | Meaning |
| --- | --- |
| `EMPEIRA_VERSION` | Installed build version, or `development` |
| `EMPEIRA_ADDON_API_VERSION` | `1` |
| `EMPEIRA_ADDON_NAME` | Configured logical name |
| `EMPEIRA_ADDON_VERSION` | Configured Git ref |
| `EMPEIRA_ADDON_PATH` | Absolute resolved commit snapshot directory |
| `EMPEIRA_WORKSPACE` | Absolute canonical workspace project directory |
| `EMPEIRA_CONTROL_REPO` | Absolute canonical control repository root |

Workspace means the existing project identity, not a running lab. Project-bound
CLI calls require the existing Git-root `.empeira.yaml` marker, including when
invoked from a subdirectory. No workspace infrastructure is created for an addon.
Context variables are omitted if a caller has no such context.

The schema explicitly excludes `vm.console.root_password`, `eyaml.private_key`,
`browser.start_url`, `server.runtime.startup.arguments`,
`puppetdb.runtime.java_arguments`, `puppetdb.runtime.main_arguments`, and each
additional container's `environment`, `command` and `configuration.content`.
These include opaque content which may contain secrets under ordinary names; this
is not a suspicious-key-name filter. Other validated configuration is exported.
No private key files are read for export.

Normal inherited user variables remain available. All inherited `EMPEIRA_*` names
are cleared before the authoritative configuration and runtime values are set, so
stale, forged or excluded values cannot leak through that namespace. Environment
plus argv size is checked against the OS limit, with pointer/headroom allowance
and a conservative 128-KiB per-string limit. Oversized data or null bytes fail
before execution without printing values; there is no file-based fallback.

## Bash completion

Use the existing registration:

```bash
source <(empeira completion bash)
```

It completes `addons list/info/sync/update`, names after `addons info` and `addon`,
then local manifest commands, options and enum values. Positional and option
`file`/`directory` arguments use native Bash filename completion, including relative
and absolute paths, subdirectories, spaces and shell punctuation. `--option=value`
is supported as well as a separate value. `--` ends option parsing.

Completion reads only configuration and installed manifests. It never fetches Git
sources or calls an addon executable. A configured missing addon name is offered,
but its commands become available only after installation. Missing or invalid
manifests produce no addon candidates and leave Core completion usable. There is
no additional completion executable, script to install or cached file list.

## Development, trust and troubleshooting

The complete [minimal fixture](../spec/fixtures/addon/README.md) can be copied into
a separate Git repository. It prints arguments and demonstrates all completion
types. It does not implement a production converter, data sync or Git hook tool.
Keep runtime dependencies and platform instructions in the addon's README. An
addon can read the environment in any language and uses the caller's current
directory and inherited stdin/stdout/stderr. Terminal colors and interactive input
remain available. The CLI process is replaced by the executable: exit statuses and
signal termination remain native, without an intermediary process swallowing them.
Start failures distinguish 126 (not executable) and 127 (entrypoint/interpreter
not found); actual addon failure exits are returned unchanged.

Addons run as the invoking user. They are trusted local programs, **not sandboxed**.
The export filter limits what Core supplies; it cannot prevent a trusted program
from reading files or credentials already accessible to the user. Review sources
before execution and prefer immutable commits for reproducibility. Git source
authentication continues to use the user's existing Git/SSH tools; credentials
are not copied into an addon cache by Empeira. Git diagnostics use Core redaction;
addon stdout/stderr are direct program output and remain the addon's responsibility.

Supported platforms are native Linux, native macOS and Linux in WSL2. Native
Windows is unsupported. Host Git, the normal Empeira Ruby requirements and any
addon interpreter/binary prerequisites must be installed. No Docker or Podman is
needed to install, manage or execute addons.

For a missing addon, check the effective `addons` mapping and run `addons sync`.
For an unknown ref, verify it with the source owner and correct `ref`. For Git
authentication failures, use the normal host Git/SSH configuration. For a missing
or invalid manifest, fix it upstream and update to a valid revision. For 126/127,
check the executable bit, shebang, interpreter and host architecture. If a cache
is incomplete, stop users of that source and remove only its affected source
namespace before synchronizing again; never delete a live lock as recovery.
For missing command completion, inspect `addons info NAME` and source the current
Bash completion again after an Empeira upgrade.
