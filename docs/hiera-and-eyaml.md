# Hiera and EYAML

The canonical selected control repository is mounted read-only at
`/etc/puppetlabs/code/environments/production`. Change `server.environment` to use
another ordinary Puppet environment name. Environment caching is disabled so local,
uncommitted manifests, modules and data are visible without image rebuilds. The
repository supplies its normal `environment.conf`, `hiera.yaml`, manifests and
vendored modules. Puppetfile modules are synchronized explicitly with `update modules` into `modules.path`.
Empeira adds only `facts.empeira.provider` to nodes before their
first catalog. It does not edit the repository's `hiera.yaml`.

Repositories that need disposable-node overrides can optionally add this hierarchy:

```yaml
hierarchy:
  - name: "Empeira provider"
    path: "virtual/empeira-%{facts.empeira.provider}.yaml"
  - name: "Virtualization"
    path: "virtual/%{facts.virtual}.yaml"
```

The first path resolves to `virtual/empeira-container.yaml` or
`virtual/empeira-vm.yaml`. `facts.virtual` remains Facter's own platform fact.
The files can live in the normal control repository or existing Hiera mounts;
generic repositories need no Empeira-specific hierarchy.

## External Hiera repositories

Configure Puppet-aware mounts in `.empeira.yaml`:

```yaml
hiera:
  mounts:
    - source: ../hieradata-register
      type: module
      name: hieradata_register
    - source: ../hieradata-secure
      type: module
      name: hieradata_secure
    - source: ../environment-data
      type: environment
      target: data/external
      required: true
```

`module` mounts appear read-only at
`/etc/puppetlabs/code/environments/<server.environment>/modules/<name>`.
Names must start with a lowercase letter and contain lowercase letters, digits or
underscores. `environment` mounts appear at the configured relative `target` below
the same environment root. Absolute targets, `.`/`..` segments, unsafe mount syntax,
duplicate targets and overlapping parent/child targets are rejected, including
collisions across mount types. Existing destination symlinks must stay inside the
environment. Generic absolute container destinations are not supported.

Relative sources resolve against the canonical control-repository root; absolute
local sources are supported. Existing paths are canonicalized, including macOS
`/var` symlinks. Sources may live outside the control repository. `required` defaults
to `false`: missing, inaccessible or dangling optional repositories produce a visible
warning during `up` and are skipped. `required: true` makes unavailability fatal.
Existing non-directories, looping symlinks and malformed definitions remain errors.
An optional mount is not permission to ignore unsafe configuration.

Puppet's [default modulepath](https://help.puppet.com/core/current/Content/PuppetCore/config_file_environment.htm)
includes the environment's `modules` directory. Empeira checks explicit
`environment.conf` modulepaths and reports a known exclusion before startup. It
never rewrites that file. Expressions containing unresolved Puppet variables cannot
be verified completely from the CLI host; ensure the effective server modulepath
includes the mount destination. Environment mounts can be referenced by ordinary
relative paths in `hiera.yaml`, such as `data/external` or `external` when the datadir
is already `data`.

All repositories stay live and read-only. Changes inside mounted Hiera repositories
are visible to the next catalog request with `environment_timeout = 0`, without
an image rebuild, `up`, or a service restart.
Empeira neither copies their data nor writes probe files into them. It uses a managed
environment directory containing links to the read-only control repository so nested
mount targets can exist without modifying control code. Existing control files and
linked directories remain live. `up` refreshes links for new control entries under
projected ancestor directories. EYAML keys remain configured separately in `eyaml`,
and decryption runs on the server.

`config show` includes `effective_hiera_mounts` with resolved destinations and
`available`/`skipped` states. These are desired mount observations, not a container
readiness claim. Mount definitions, required flags and source availability affect
only the server fingerprint; Hiera file contents are not hashed. Run `up` after
changing mount definitions or making a skipped source available to reconcile the
server.

## Puppetfile modules

`empeira update modules` resolves Hiera mounts and synchronizes the root `Puppetfile`.
Run it explicitly before `up` when required modules have not been installed. `up`
consumes existing modules without r10k, Forge or Git access and never repairs them.
An obviously missing module tree fails early with:

```text
Puppetfile modules are not available.
Run: empeira update modules
```

Without a Puppetfile, the repository's existing module layout continues to work unchanged.

```yaml
hiera:
  mounts:
    - source: ../hieradata
      type: module
      name: hieradata
      required: false
```

When `../hieradata` is available, Empeira uses that local repository and does not
install the matching Puppetfile module. When the optional path is unavailable,
Empeira warns and skips its mount. `update modules` installs the Puppetfile version;
`up` uses that existing fallback or reports missing modules. With
`required: true`, an unavailable local repository aborts before synchronization;
there is no fallback. Only available `type: module` entries are overrides.
`owner-hieradata`, `owner/hieradata` and `hieradata` normalize to the module name
`hieradata`. Duplicate normalized Puppetfile names are errors, including overrides.

The installer uses the pinned [r10k Puppetfile loader](https://github.com/puppetlabs/r10k)
and its native `module_exclude_regex`, before module synchronization. The Puppetfile
is evaluated once in the disposable update helper. Its validated installation plan is
then used for host Git acquisition and r10k synchronization without reevaluation.
Empeira never rewrites the original Puppetfile. r10k synchronizes modules directly
into `modules.path`, reusing existing installations and native Git/r10k caches.
The existing managed environment projection exposes installed modules at the normal
`/etc/puppetlabs/code/environments/<environment>/modules` path. Parent environment
mounts precede local Hiera mounts, which stay live and read-only. An explicitly
excluded `modules` path in `environment.conf` remains an error. Git-tracked module
contents are protected before synchronization. Undeclared directories in the managed
path are retained; Empeira does not purge them. Environment mounts overlapping `modules` are
rejected when a Puppetfile exists; use module mounts for overrides.

Git entries support HTTPS/HTTP, `ssh://` URLs and normal SCP-style Git URLs such as
`git@private-alias:team/profile.git`, with `ref`, `branch`, `tag` or `commit`.
Without a selector, the acquired remote's HEAD is used. Prefer a full commit ID
for reproducibility. Forge entries support exact versions and r10k's `:latest`;
pin versions for reproducibility. Unpinned branches and `:latest` are resolved only
during synchronization, not on every `up`. Custom
Forge endpoints use the ordinary Puppetfile `forge` directive. `moduledir` and
`install_path` must resolve to `modules`; alternate installation trees, SVN, local
Puppetfile entries, `:control_branch`, embedded HTTP credentials and SSH URL passwords
are unsupported and fail clearly. An excluded override does not need a usable
remote or ref. Git source acquisition runs on the host as the invoking user, using
normal Git/OpenSSH behavior: SSH agent, identities, `~/.ssh/config`, aliases,
ProxyJump, known hosts and VPN routing. Empeira supplies no SSH flags or replacement
identity, copies no private keys, and manages no Git credentials. Interactive Git
retains terminal access for authentication; unattended execution needs an already usable identity/agent.
Persistent bare Git mirrors are kept in the normal external Empeira state and updated
incrementally using host Git. The helper reads these mirrors and reuses r10k's native
cache and working copies; no temporary bundles or fresh module trees are produced.
Neither SSH sockets nor private keys enter the helper. Empeira disables Git template
copying when creating mirrors, so user template hooks are not copied.

The installer receives a copy of the Puppetfile, not the control repository or host
SSH configuration: external Ruby includes and host-dependent Puppetfiles are unsupported.
Puppetfiles remain trusted executable Ruby input. The helper is configured through
`images.r10k.build: modules/Containerfile`; its reviewed recipe produces
`localhost/empeira-r10k:<recipe-hash>` and includes Ruby, r10k, Git and CA certificates.
The obsolete `images.modules` key is rejected.

The disposable installer belongs to the update plane. It uses the selected
runtime's normal bridge network (`bridge` on Docker, `podman` on Podman), with
normal runtime DNS and external connectivity. It never joins an Empeira workspace
network and needs neither CoreDNS nor Squid. Workspace `network.egress`, `proxy.enabled`,
`proxy.global` and `proxy.rules` do not affect
Forge or Git acquisition. Supplied `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and their
lowercase equivalents are inherited unchanged; Empeira generates no proxy URL.
The host/runtime's normal network and corporate-proxy configuration must permit
Forge access, including redirects. Node and service isolation remains unchanged.

The helper bind-mounts readonly Puppetfile/request inputs and source mirrors, plus the
writable `modules.path` and native r10k cache. The caches stay outside the control
repository in the normal workspace state. It runs with the invoking user's UID/GID
(Podman uses `keep-id`) and dropped capabilities. Per-invocation ownership and observed
network membership are verified. Success, failure and interruption remove the owned
helper where the engine remains reachable; no persistent service or internal DNS
identity is created. Reviewed image builds contain no control code or credentials.

`up` performs a shallow availability check, without evaluating Puppetfile Ruby or
contacting any source. An existing small external list of module names helps detect
missing directories and unavailable optional-override fallbacks. Manually populated
module directories can also be used without this metadata. An explicit successful
zero-module update permits an empty directory. This is a plausibility check, not a
version/content check: Puppetfile changes never trigger automatic synchronization.
Module acquisition has no freshness fingerprints or implicit repair actions. The
server reloads live code for each catalog with `environment_timeout = 0`; it never
requests or enforces module synchronization.

`empeira update modules` always synchronizes, including moving refs, directly into the
configured directory. Existing Git repositories are fetched incrementally, and r10k
reuses installed modules where possible; unchanged Forge releases are not downloaded
again. Native r10k synchronization may reset local edits to managed modules. Use local
Hiera mounts for maintained overrides. Updates work before the first `up` and after
`down` or `destroy`; they do not start services or rewrite infrastructure inventory.
Both commands use the existing version gate and workspace mutation lock.

A running server can see changes immediately through its readonly module mount.
There is no deployment generation, activation pointer or subsequent `up` requirement
for module content changes. This is intentional for a disposable local test environment.
The next catalog request sees the edits, including from agents invoked outside Empeira.
Empeira does not automatically run Puppet agents. A failed or interrupted update may
leave partially updated modules visible; there is no rollback. Inspect the reported
module/ref/version or connectivity error and rerun `update modules`. The installed-name
list is invalidated before a sync. `up` may consume plausible partial contents;
it never retries the update. Recovery is an explicit `update modules`.

Both `down` and `destroy` retain the actual module directory, native source/r10k caches
and small installed-name list. The next `up` consumes these existing dependencies without downloading
again. Module and cache removal is a separate manual action.

During synchronization, the existing two-line progress display shows the current
module name and completed count, for example `profile (14/28)` at 50%.
The total excludes available local overrides. A module is counted only after its
complete r10k sync succeeds; Git acquisition displays its name without incrementing
the counter. An empty effective Puppetfile completes at 100% without division by zero. Local module mounts appear as
`name (local override)`. Redirected output and CI use the same messages as plain
lines. Successful Git, SSH, HTTP, Forge and r10k output is buffered and never
printed as a subprocess transcript. Authentication prompts can still use the
user's terminal; Empeira does not disable normal Git/SSH authentication.

On failure, Empeira reports the module and bounded, filtered diagnostic lines for
authentication, DNS, HTTP, versions and refs. Commands, authorization headers,
private key material, filesystem paths and credential-bearing URLs are suppressed
or redacted. A failed module is not counted, and failure never emits a successful
completion event. Check the reported
cause before retrying; raw successful subprocess logs are not part of normal output.

`modules.path` is the actual module directory, relative to the canonical control
repository root unless absolute. The default:

```yaml
modules:
  path: modules
```

produces a flat installation:

```text
<control-repo>/modules/
├── stdlib/
├── concat/
└── profile/
```

`path: ../puppet-modules` instead installs directly into that sibling directory.
There are no `.empeira`, workspace or generation subdirectories beneath the module
path. Internal metadata and caches stay in the platform workspace state. The server
sees the configured directory at its normal environment `modules/<name>` path.
Available local Hiera overrides are mounted over destination directories in that
tree (created empty if missing); their source remains live and readonly. Changing `modules.path` requires
`up` to change the server mount, but does not delete the previous directory.
Old generation directories from development versions are neither adopted nor deleted
automatically; they can be removed manually after the old infrastructure is torn down.

If the path is inside the canonical control repository, Empeira checks it with Git
before synchronization. Git-tracked contents anywhere under that path are a hard
error before changing module output. For an untracked path
not covered by Git's ignore rules, Empeira prints one repository-relative
recommendation per command and continues. It never edits `.gitignore`. Nested
ignore files, `.git/info/exclude` and configured global excludes are respected.
An external module directory needs no Git-ignore recommendation.

With the default path, the recommendation is:

```text
Recommendation: modules/ is not ignored by Git. Add /modules/ to .gitignore.
```

If the repository already tracks vendored modules there, select a different
`modules.path`; tracked files are never overwritten or deleted by synchronization.

## EYAML

Enable server-side PKCS7 keys explicitly in `.empeira.yaml`:

```yaml
eyaml:
  enabled: true
  private_key: secrets/private_key.pkcs7.pem
  public_key: secrets/public_key.pkcs7.pem
```

Relative paths resolve against the canonical project root. Absolute paths are also
supported. Both must resolve to readable regular files. The private key is a PEM
RSA private key for PKCS7 and the public file is its PEM X.509 certificate, as generated
by `eyaml createkeys`. Keep keys outside version control. Empeira neither generates
nor copies these keys into the repository, inventory or images. It mounts the files
read-only, exclusively in the configuration server. OpenVox mounts them directly;
the Puppet Server image changes ownership recursively under `/etc/puppetlabs/puppet`
at startup, so Empeira mounts its sources outside that tree and stages the keys in
a container-local tmpfs. Both providers expose the keys to Hiera at:

- `/etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem`
- `/etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem`

Point the existing control repository's `hiera.yaml` at these paths, for example:

```yaml
version: 5
hierarchy:
  - name: Encrypted common data
    lookup_key: eyaml_lookup_key
    path: common.eyaml
    options:
      pkcs7_private_key: /etc/puppetlabs/puppet/eyaml/private_key.pkcs7.pem
      pkcs7_public_key: /etc/puppetlabs/puppet/eyaml/public_key.pkcs7.pem
```

The server's JRuby environment must include `hiera-eyaml` (the default OpenVox
image includes it). The runtime must expose the source files through its UID
mapping and shared filesystem. Empeira verifies engine visibility
without printing file contents. It does not detect EYAML usage automatically or
rewrite `hiera.yaml`. `config show` redacts the private-key path under the existing secret-redaction
model and never displays key contents.
For Puppet Server, run `empeira up` after changing a key file to refresh the
container-local tmpfs copy without recreating the server.
EYAML is disabled by default.
