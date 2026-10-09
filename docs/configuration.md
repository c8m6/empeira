# Configuration

Empeira runs `git rev-parse --show-toplevel` through the central execution runner
from the current directory, canonicalizes the returned root (including macOS
symlink paths), and requires `<git-root>/.empeira.yaml`. The marker explicitly opts
that Git repository into Empeira. Invocation from any subdirectory works; there is
no `--project` override or Puppet-repository heuristic. Missing Git/markers produce
actionable errors including the resolved root and `touch` command.

An empty file or `{}` uses defaults. Nonempty configuration must be one YAML mapping.
Duplicate keys, multiple documents, aliases and object tags are rejected. Unreadable
files and broken marker symlinks fail. Help/version/self-update are project-independent.

Precedence, from lowest to highest:

1. [Built-in defaults](../config/defaults.yaml).
2. The selected control repository's `.empeira.yaml`.
3. Optional host preferences in `~/.empeira.yaml`.
4. Explicitly permitted CLI overrides.

Mappings deep-merge; scalars and arrays replace lower-precedence values. Explicit
`null` is allowed only where the schema permits it. Every source is validated
before merging, so a later override cannot hide an invalid project setting.
Cross-field validation runs against the effective configuration.

## Optional user preferences

`~/.empeira.yaml` holds local workstation preferences and is not committed to the
control repository. A missing or empty file is normal and produces no warning.
It may contain exactly these settings, independently or together:

```yaml
runtime:
  container_engine: docker
images:
  registry: registry.example.net
```

User preferences override the same project keys; an explicit `--container-engine`
overrides the user preference. All other project mappings remain intact. For example,
a project selecting Podman and `images.registry: null` uses Docker and the cache above
on this workstation without changing the repository. Explicit user `registry: null`
restores Docker Hub resolution. `config show` displays the effective non-sensitive values.
There is no separate source-reporting option.

This file is deliberately not a second project definition. Any other key, including
`server`, `agent`, `network`, `containers`, `browser`, `images.server`, `images.nodes`, or
credential fields, fails with the user-file path and offending YAML path. Duplicate
keys, aliases, object tags, multiple YAML documents and control-character keys are
rejected just as for project YAML. Invalid lower-precedence values cannot be hidden
by a later override. A user file does not replace the required project opt-in marker.
Home resolution uses Ruby/platform facilities on Linux, macOS and WSL2.

## Project configuration

Example `.empeira.yaml`:

```yaml
version: 1
requirements:
  empeira: null # Set a release requirement when using a released Empeira build.
runtime:
  container_engine: podman
server:
  environment: production
network:
  egress: []
proxy:
  enabled: false
node_defaults:
  os: ubuntu
  version: "24.04"
  memory: 2048
  cpus: 2
puppetdb:
  enabled: true
bootstrap:
  enabled: false
  scripts: []
  packages:
    install: {default: [], debian: [], redhat: []}
    remove: {default: [], debian: [], redhat: []}
```

`version: 1` is the configuration schema version, unrelated to the application
release version. A partial project mapping may omit it and inherit the default.
`node_defaults.version` is an OS version string and must be quoted if numeric.

| Path | Type and default |
| --- | --- |
| `version` | Integer, exactly `1` |
| `requirements.empeira` | RubyGems requirement string, or `null` (default) |
| `runtime.container_engine` | `podman` (default) or `docker` |
| `server.runtime` | OpenVox startup defaults; optional startup, configuration path and environment-key overrides for compatible custom images |
| `puppetdb.runtime` | OpenVoxDB process defaults; optional entrypoint, user, Java arguments, paths and environment key overrides for compatible custom images |
| `images.server` | OpenVox Server OCI image by default; repository/tag, digest or exact reference |
| `images.puppetdb` | OpenVoxDB OCI image by default; independent of the server image |
| `images.postgres` | PostgreSQL OCI image, independently replaceable |
| `agent.package`, `agent.version` | Defined in [built-in defaults](../config/defaults.yaml); independent of server images |
| `agent.install.method` | `repository` (default) or `package` |
| `agent.install.repositories.KEY` | Pinned OpenVox release packages and reviewed destinations by default |
| `agent.install.apt.KEY`, `agent.install.dnf.KEY` | Native sources with a generic `default` and partial OS overrides |
| `agent.install.packages.KEY.ARCH` | Direct HTTPS `.deb`/`.rpm` URL, optional SHA-256 and signature policy |
| `agent.cache.enabled` | Shared host package cache, enabled by default |
| `server.environment` | Puppet environment name, `production` |
| `server.memory`, `server.cpus` | Positive integers, `1536` MiB and `2` CPUs |
| `server.timeout` | Positive readiness timeout in seconds per component, `240` |
| `server.mounts` | Additional server-only host bind mounts, `[]`; `source`, `target`, optional boolean `readonly` (default `true`) |
| `puppetdb.memory` | Positive integer MiB, `768` |
| `network.egress` | Direct TCP proxy-bypass host/port entries, `[]`; a project array replaces the default array |
| `network.redirects` | Exact external IPv4/TCP pairs redirected to enabled internal services, `[]` |
| `proxy.enabled` | Boolean, `false`; creates the normal HTTP/HTTPS policy proxy |
| `proxy.global` | DNS destination array, `[]` |
| `proxy.rules` | Additive hostname-glob rules with `hosts` and `allow` arrays, `[]` |
| `vm.console.root_password` | Initial console password, `empeira`; a string overrides it and `null` disables it |
| `dns.upstream` | `mode: host` and empty `servers` by default; explicit mode requires resolver IPs |
| `dns.additional_resolver` | Optional DNS name or IP address queried before the existing upstream for non-Empeira names; NXDOMAIN/NODATA fall through |
| `dns.rewrites` | Exact external hostnames mapped to enabled `<service>.empeira.internal` targets; `[]` by default |
| `hiera.mounts` | Puppet-aware module/environment mounts, `[]`; each source is optional unless `required: true` |
| `node_defaults.os` | Configured node OS family, default `ubuntu` |
| `node_defaults.version` | OS version string, default `"24.04"` |
| `node_defaults.init` | `process` by default; `systemd` requires supported Podman/cgroup v2 |
| `node_defaults.memory` | Positive integer MiB, `1024` |
| `node_defaults.cpus` | Positive integer, `2` |
| `mocks.commands` | Named command stubs for test nodes, `{}`; each requires `path`, `mock_to` and `exit_code` |
| `puppetdb.enabled` | Boolean, `true` |
| `eyaml.enabled` | Boolean, `false`; requires both key paths when enabled |
| `eyaml.private_key`, `eyaml.public_key` | Local PEM file paths, `null` by default |
| `bootstrap.guests` | Reviewed agent-presence metadata and bootstrap-proxy destination domains; Rocky and AlmaLinux supply stable package base URLs |
| `bootstrap.packages.install` | Global one-time package lists for `default`, `debian` and `redhat` |
| `bootstrap.packages.remove` | Global one-time removal lists for `default`, `debian` and `redhat` |
| `images.direct_egress` | Recipe or explicit image reference implementing the workspace gateway contract |
| `images.r10k.build` | Disposable r10k helper recipe, `modules/Containerfile` |
| `modules.path` | Actual directory containing modules directly; `modules` by default, relative to the canonical repository root or absolute |
| `bootstrap.enabled` | Boolean, `false` |
| `bootstrap.scripts` | Project-local UTF-8 script paths, `[]`; run during VM cloud-init only when enabled |
| `images.registry` | Optional default registry host; `null` resolves hostless repositories through `docker.io` |
| `browser.image` | Configurable repository/tag, `docker.io/linuxserver/chromium:latest` |
| `browser.start_url` | Initial Chromium page, `about:blank` |
| `containers.additional` | Array of infrastructure service definitions, `[]` |

Unknown keys, unused namespaces, named nodes, and `node_defaults.provider` are
rejected. `puppetdb.enabled: false` omits PostgreSQL/PuppetDB and disables server
storeconfigs/report integration, preserving any previously created database volumes.

### DNS rewrites for internal services

Use an additional infrastructure service as a local API Compatibility Layer:

```yaml
dns:
  rewrites:
    - from: ipam.example.net
      to: api-layer.empeira.internal
    - from: inventory.example.net
      to: api-layer.empeira.internal
containers:
  additional:
    - name: api-layer
      image:
        repository: registry.example.net/lab/api-layer
        tag: "1"
```

Each entry requires exactly `from` and `to`. Hostnames are case-insensitive; a
trailing root dot is accepted. Duplicate sources, wildcards, regular expressions,
URLs and IP addresses are rejected. Sources must be outside `empeira.internal`,
which prevents self references and cycles. Targets must name an enabled built-in
or additional service, using exactly `<service>.empeira.internal`; node names and
nested names are not service targets. `up` reports missing or disabled targets
before acquiring images or changing infrastructure.

Run `empeira up` after adding, changing or removing a rewrite. CoreDNS reloads its
configuration while preserving its container and existing container/VM nodes.
Service-discovery updates supply the current target IPv4 address; no IP belongs in
the rewrite configuration. Repeated unchanged `up` calls do not reload the policy.
See [DNS rewrites](networking.md#exact-dns-rewrites) for DNS response semantics.

A DNS rewrite changes name resolution only. Applications still send the original
HTTP Host/TLS SNI name and use their original protocol and port. The service must
implement the desired API behavior and, for HTTPS, present a certificate valid for
the original hostname that the client trusts. Empeira supplies no TLS termination,
certificate management, HTTP transformation, port mapping or proxy-policy changes.

### Additional server bind mounts

Projects can expose local artifacts to the Puppet/OpenVox configuration server:

```yaml
server:
  mounts:
    - source: ../artifacts
      target: /srv/puppet-artifacts
    - source: /srv/example-ca
      target: /etc/example-ca
      readonly: true
```

Relative sources resolve against the canonical Git control-repository root, even
when invoking Empeira from a subdirectory. Absolute sources outside the repository
are allowed. Sources must exist and resolve through `realpath` to regular files or
directories; broken source symlinks, control characters and commas are rejected.
Targets must be absolute, are normalized, and cannot contain `..` segments or
control characters/commas. `/` itself and system paths `/dev`, `/proc` and `/sys`
cannot be mounted. Source data trees must not contain sockets, devices or other
special files. Validation does not follow nested directory symlinks.

Mounts are read-only unless explicitly configured with `readonly: false`. Writable
mounts allow the server to change host data, subject to host filesystem permissions.
The runtime must be able to see the canonical host path, including when its engine
runs in a VM. Empeira checks mounted visibility using the existing mount probe.
This interface accepts no named volumes, tmpfs, device/runtime-socket mounts,
propagation flags, SELinux options or arbitrary Docker/Podman mount strings.

The mounts belong exclusively to `server.empeira.internal`. For example, a manifest
can use `file('/srv/puppet-artifacts/banner.txt')` during catalog compilation to
supply a Puppet `file` resource's content, if that is what the control code expects.
Empeira provides the bind mount without adding Puppet-specific file handling.
It does **not** expose the host path to agent nodes: a server-local path is not
automatically an agent-local `source` path. Container/VM nodes, PuppetDB, PostgreSQL,
DNS, proxy, browser, additional services and the r10k helper receive no such mounts.

Duplicate targets and ancestor/descendant overlaps between project mounts are
rejected. The same collision check covers all actual Empeira-managed server mount
targets, including CA, SSL, server data, the environment/control repository,
modules, Hiera, EYAML and PuppetDB startup/configuration files when enabled.

Mounted directory content stays live: editing files requires no server recreation.
Contents are not hashed. Changing the canonical source, normalized target or
`readonly` changes the server service fingerprint; the next `empeira up` uses normal
selective reconciliation to recreate the server. There is no hot-mount operation.
For an individually mounted file, edit it in place: editors that replace its inode
may require recreating the server. Mount its containing directory for atomic file
replacement to remain visible.

### Command mocks on test nodes

Use `mocks.commands` for Puppet tests that need external commands to exist and
respond successfully or with a controlled failure. Each mapping key is the logical
command name; any number of commands can be configured. Both container and VM nodes
use this workspace configuration.

```yaml
mocks:
  commands:
    testcmd:
      path: /usr/local/bin/testcmd
      mock_to: echo
      exit_code: 0
```

Empeira creates an executable stub at `path`. Running
`/usr/local/bin/testcmd run example` prints `testcmd run example` and exits with zero.
The echo target prints the logical name followed by every argument in order,
without interpreting options, shell expressions or backslash escapes.

To forward to a test script already present on the node:

```yaml
mocks:
  commands:
    foo:
      path: /usr/local/bin/foo
      mock_to: /opt/test/mocks/foo.sh
      exit_code: passthrough
```

The target receives the original argument vector unchanged, including empty
arguments and arguments containing spaces. Its stdout and stderr remain visible.
Empeira does not install the target script.

All three fields are required in the effective configuration:

| Field | Meaning |
| --- | --- |
| `path` | Safe absolute file destination on the node |
| `mock_to` | `echo` or a safe absolute executable path on the node |
| `exit_code` | Integer `0`–`255`, or the string `passthrough` |

**There is no default for `exit_code`.** A numeric value always overrides the
target's status, including failure to execute the target. `passthrough` returns
the target's actual exit status. Command names contain letters, digits, `_`, `.`
and `-`, beginning with a letter, digit or `_`.

The normal YAML parser, duplicate-key checks, schema and deep merge apply.
Named command mappings merge by key, and fields merge within each command.
Remove a command from the effective configuration to remove its managed stub;
with the built-in empty mapping, deleting its project entry is sufficient.
`null` is not a removal directive. Missing fields, unsupported keys, invalid
statuses, relative/traversing paths and overlapping managed destinations fail
validation.

Mocks reconcile before Puppet, on `node start`, and on `up` for running nodes.
Stopped nodes retain their files until the next start. Unchanged configuration
and files preserve file identity and timestamps. Changing a path removes the old
owned stub; changing `mock_to` or `exit_code` replaces only the affected stub.
Node/workspace destruction removes the node's storage and its mocks together.

While configured, the mock takes precedence at its exact `path`. Empeira
atomically replaces an existing regular file or symlink there and restores the
mock during the next reconciliation if another program overwrites it. The
original file is not retained. Parent directories must be real directories;
a directory at the target path is rejected. Removing a mock deletes only a
file that still matches its recorded content and ownership. Empeira does not
change packages, package databases, `PATH`, aliases or bind mounts, and the
mechanism does not simulate a cluster.

### Server images and runtime contract

An empty `.empeira.yaml` selects the OpenVox Server, OpenVoxDB and PostgreSQL
images from [the defaults](../config/defaults.yaml). Their OCI references are
independent. A project can replace any one without changing the agent:

```yaml
images:
  server:
    reference: registry.example.org/custom/server:1
  puppetdb:
    reference: registry.example.org/custom/puppetdb:1
  postgres:
    reference: registry.example.org/custom/postgres:1
```

Empeira does not identify or classify an image from its name. Docker or Podman
owns image authentication. The user supplies and licenses custom images and
must ensure that they implement the Puppet-compatible CA, server, catalog and
PuppetDB interfaces expected by Empeira. Empeira does not provide a complete
Puppet Enterprise simulation or bundle proprietary software.

`server.runtime` contains the internally managed OpenVox startup contract.
For another image, override only the fields that differ. `startup.entrypoint`
and `startup.arguments` select its normal foreground command, including when
PuppetDB and EYAML are disabled;
`startup.eyaml_keys` is `direct` or `staged`; `paths.puppetdb_config`
identifies the standard PuppetDB configuration file; `environment_keys` maps
semantic settings to environment variable names. For example:

```yaml
server:
  runtime:
    startup:
      entrypoint: /opt/custom/start
      arguments: [foreground]
    paths:
      puppetdb_config: /etc/puppetlabs/puppet/puppetdb.conf
    environment_keys:
      server_hostname: CUSTOM_SERVER_HOSTNAME
images:
  server:
    reference: registry.example.org/custom/server:1
```

The mapping deep-merges with OpenVox defaults. An alternative image using
other variable names must override each affected key. Empeira mounts standard
Puppet configuration, including `puppetdb.conf`, and supplies the configured
runtime values without inferring them from the image name. Missing or unsafe
runtime fields fail configuration validation. Managed servers use
`environment_timeout = unlimited`; Empeira invalidates its environment cache
when live code inputs change.

`puppetdb.runtime` holds the independent OpenVoxDB process contract. Custom
images may override its executable, numeric user, Java and main arguments,
`paths.jar`, `paths.config`, `paths.bootstrap_config`, and `paths.data`.
`java_arguments` is the sole JVM argument source. Empeira mounts the generated database files into
`paths.config` and retains persistent data at `paths.data`. For example:

```yaml
puppetdb:
  runtime:
    entrypoint: /opt/custom/java
    user: '1000'
    paths:
      jar: /opt/custom/puppetdb.jar
      config: /opt/custom/conf
      bootstrap_config: /opt/custom/bootstrap.cfg
      data: /opt/custom/data
    java_arguments: [-Xms128m, -Xmx512m]
```

The custom image must accept the configured JVM and PuppetDB CLI arguments.

`--container-engine podman|docker` may override `runtime.container_engine` on
configuration, infrastructure, and node commands. `node run` additionally accepts `--os`,
`--version`, `--memory`, and `--cpus`. Omitted flags preserve project settings.

```console
cd ../control-repo
empeira config show --container-engine docker
empeira config validate
```

Validation failures exit with status 1 and identify the complete path, for example
`node_defaults.memory must be a positive integer`. Configuration display applies
recursive redaction to sensitive key names. `vm.console.root_password` and sensitive EYAML paths are redacted.
Never commit real passwords or private keys into a control repository.

### Project Empeira requirements

`requirements.empeira` accepts a RubyGems requirement such as `">= 0.4.0, < 1.0"`.
The default is `null`, meaning no application version restriction.
Invalid expressions fail validation at `requirements.empeira`.

Before `up`, `down` or `destroy` takes a lock or mutates infrastructure/state, the central
build abstraction verifies this requirement. Incompatible releases fail with the
required and installed versions and the `empeira self-update` command. Self-update
itself is not implemented yet, so install a compatible build through your existing
installation method. Infrastructure operations never update Empeira automatically.
`--version`, `config show`, `config validate`, and `status` remain usable on mismatch.
If project or user configuration cannot be loaded, `destroy` uses built-in defaults
and the validated workspace inventory for recovery. An unreadable requirement cannot
be enforced in that case. Other infrastructure commands continue to reject invalid
configuration.

A `development` build has no verifiable release version. It can operate when
`requirements.empeira` is absent or null. An explicit requirement fails closed as
unverifiable. Use a compatible release build for a version-constrained project,
or a dedicated local development control repository without a release requirement.
The numeric gem packaging fallback is never used to bypass this check.

## Policy and mounts

```yaml
network:
  egress:
    - host: api.example.com
      ports: [443]
proxy:
  enabled: true
  global: [forgeapi.puppet.com]
  rules:
    - hosts: ["*-web-*"]
      allow: [github.com, "*.github.com"]
hiera:
  mounts:
    - source: ../hieradata
      type: module
      name: hieradata
vm:
  console:
    root_password: null
```

When `proxy.enabled` is true, every node may use its matching destination policy.
See [proxy policy](proxy.md),
[Hiera and EYAML](hiera-and-eyaml.md), [DNS](networking.md), and [console recovery](nodes.md#vm-console-recovery).
Mounts are optional unless `required: true`. The console password is used only on
initial VM creation. Changing it does not reset an existing node.

## Images and bootstrap

`images.nodes` selects container recipes and base images. VM image sources currently
resolve reviewed Ubuntu/Rocky upstream URLs in the image-source adapter; they are
not configurable through an `images.vm` namespace. A custom adapter can be injected
at the provider boundary. `bootstrap.guests` records whether an agent is preinstalled
and the reviewed destination domains that the temporary bootstrap proxy may reach.
Rocky metadata also supplies the stable `baseurl` needed to avoid arbitrary mirror
selection. Ubuntu and Debian package source URLs come exclusively from the base
image. For the reviewed Ubuntu images, amd64 permits archive/security domains and arm64
permits the ports domain. Do not mark stock cloud images as agent-preinstalled.
See [node images](nodes.md#node-images-and-fidelity) for fidelity and licensing.

### Agent sources and shared package cache

With an empty project marker, the pinned OpenVox release packages, agent version,
server and database images remain the defaults. Release packages configure the
signed source inside a disposable host-side helper, never on the test node.
The helper uses the selected runtime's default bridge and target OS image; APT/DNF
need not be installed on the host. No agent is installed on the host or helper.

A generic source can serve all supported releases of its package-manager family:

```yaml
agent:
  package: puppet-agent
  version: "8.20.0"
  cache:
    enabled: true
  install:
    method: repository
    apt:
      default:
        url: https://packages.example.org/apt
        component: main
      ubuntu24.04:
        suite: noble-special
    dnf:
      default:
        url: https://packages.example.org/yum/$releasever/$basearch
```

Configure only the manager you use. A project `apt.default` or `dnf.default`
supersedes the built-in release sources for that family. OS-specific entries
merge over the generic default; existing complete source definitions and `suffix`
overrides remain supported. APT suites default to `jammy` for Ubuntu 22.04 and
`noble` for Ubuntu 24.04. RPM keys remain `el8`/`el9` for Rocky, AlmaLinux and
Oracle Linux's existing supported releases. Architecture comes from the target
node: `amd64`/`arm64` for DEB and `x86_64`/`aarch64` for RPM. Only `$suite`,
`$releasever` and `$basearch` URL placeholders are expanded; arbitrary environment
interpolation is rejected.

Native source metadata resolves the exact software version to a complete native
version. No newest-version fallback is used, and ambiguous releases require an
explicit native version or `suffix`. Resolution excludes unrelated repositories.
The downloaded package's name, version and architecture must match the target.

Direct HTTPS artifacts use the same acquisition and installation path:

```yaml
agent:
  package: puppet-agent
  version: "8.20.0"
  install:
    method: package
    packages:
      ubuntu24.04:
        amd64:
          url: https://packages.example.org/puppet-agent.deb
          # Optional; if present, the pin is mandatory on downloads and cache hits.
          sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
```

Direct files remain explicit by distribution and architecture; Empeira does not
invent download URLs. A software version is accepted when package metadata
matches it exactly; a complete native version pins the release as well.

`sha256` is optional for custom release/key artifacts and direct packages.
Built-in OpenVox release checksums remain pinned. A configured pin is always
verified. Changing a source or key URL clears its inherited checksum unless
the override supplies a new pin. Signed APT metadata supplies package checksums;
RPM signatures are checked natively. Local DEBs have no repository signature chain: HTTPS and an
optional independent checksum pin are their verification mechanisms.
The cache's calculated checksum detects corruption, not publisher provenance.

Native signature checks stay enabled. Existing trusted keys may be used; an
optional `key: {url: https://..., sha256: ...}` supplies an additional public key.
An APT source can also retain its existing `release` artifact. Set
`verify_signatures: false` on an APT/DNF source or direct package only when you
intend to use an unsigned source. The exception is scoped to that source or local
RPM; base-source signature checks and HTTPS verification remain active. Temporarily
imported RPM keys are removed after installation without removing preexisting keys.

Packages are shared across workspaces under the current user's cache:

| Host | Agent cache |
| --- | --- |
| Linux / WSL2 | `$XDG_CACHE_HOME/empeira/agents` or `~/.cache/empeira/agents` |
| macOS | `~/Library/Caches/empeira/agents` |

Only packages and necessary nonsecret metadata, including public signing keys,
are retained. Identity includes package name, full native version, OS family,
distribution/release, target architecture, format and source/verification policy.
Private directories, per-request filesystem locks, temporary downloads and atomic
publication protect concurrent callers. Hits validate local metadata, package hashes
and any configured package SHA-256 pin. A valid hit is fully usable offline, including
packages acquired from private APT/DNF repositories or direct authenticated HTTPS
downloads: no HTTP request, credential validation or login is needed for reuse.
Damaged owned entries are reacquired. Foreign, symlinked or insecure entries fail
closed. `agent.cache.enabled: false` bypasses the persistent cache entirely, uses
temporary host storage with the same acquisition path, removes it after use and
leaves existing cache entries intact. There is no cache-cleanup command.

HTTP authentication occurs only when acquisition is necessary, such as a cache miss,
a damaged artifact or disabled caching. It uses `EMPEIRA_AGENT_REPO_USERNAME` and
`EMPEIRA_AGENT_REPO_PASSWORD` when both are set. Invalid explicit credentials fail
without an interactive fallback. Otherwise an HTTP 401 can prompt in a TTY:
confirm login, enter the username and enter the password without echo. Progress
is suspended during the prompt. There is one retry; cancellation or another
failure stops provisioning. Without a TTY, the error names the two environment
variables for CI. HTTP 403 and proxy HTTP 407 do not trigger repository login.
ENV credentials take precedence. A rejected interactive login is identified as
such and includes the last HTTP diagnosis. During acquisition, the login is reused
for related metadata, signing-key and package requests to the same HTTPS origin
(case-insensitive hostname and matching port). Credentials are not forwarded to
other origins; a 401 there names the failing URL rather than asking for the source's
login again.

Credentials stay in memory or temporary 0600 helper files, never in YAML, cache
keys, cache metadata, workspace inventory or process arguments. Host downloads
do not follow redirects, and credentials are scoped to the source HTTPS origin.
Registry authentication continues to use native `docker login` / `podman login`.

After configured bootstrap packages are handled using the guest's base sources,
the host artifact is uploaded through existing container/VM file transport and
installed locally by APT/DNF. The agent repository is not added to the node.
Dependencies can still require the unchanged guest base repositories and existing
bootstrap-proxy grants: this is an agent-artifact cache, not an offline package
mirror. No additional node egress is granted. Dependency failure blocks the first
catalog. Uploaded artifacts, temporary keys and proxy files are removed, and the
original package-manager configuration is restored and verified before bootstrap
access is removed, enrollment completes and Puppet runs. Unverifiable cleanup
leaves the node incomplete for diagnostics.

APT loads the private proxy file explicitly after the guest's normal configuration
so existing proxy fragments cannot override the controlled bootstrap endpoint.
Credentials are redacted before diagnostic truncation, including native errors
that print a raw credential rather than a URL.

`bootstrap.enabled: true` runs `bootstrap.scripts` once during VM cloud-init.
Scripts must be project-local UTF-8 files below 1 MB, including after symlink
resolution. This does not control the built-in agent installation, which works
without project bootstrap scripts or normal Internet access. Remote project
scripts are not implemented. Keep secrets out of bootstrap scripts.

`bootstrap.packages` is a separate, provider-independent package bootstrap for a
new node instance. Empeira concatenates `default` with the detected distribution
family for each action. Ubuntu and Debian select `debian`; RHEL, Rocky Linux,
AlmaLinux and Oracle Linux select `redhat`. Package names remain literal YAML values;
Empeira has no package-name translation table. The native manager removes packages
first, then refreshes package metadata when installation is needed, then installs.
APT is used for the Debian family and DNF for the Red Hat family.

```yaml
bootstrap:
  packages:
    install:
      default: [git, curl]
      debian: [libxml2-dev]
      redhat: [libxml2-devel]
    remove:
      default: [telnet]
```

The operation uses the temporary authenticated bootstrap proxy and reviewed active
agent and distribution package destinations. For Ubuntu and Debian VMs, Empeira
archives the complete `/etc/apt` tree before package and agent bootstrap, then
restores that tree and verifies the
restored archive before removing bootstrap access. The read-only active-source check
then runs against the restored configuration before certificate enrollment and the
first Puppet catalog. Empty lists cause no package-manager call.
A failed remove, metadata refresh or install retains the node and prevents Puppet.
Empeira also verifies that its required agent executable and Ruby remain available
after these package operations. Choose the agent through `agent.install`; do not install a replacement agent through
`bootstrap.packages`.
Stop/start, later Puppet runs and repeated `up` do not repeat it. Destroying and
creating a new node instance runs it again. This is initial preparation, not Puppet
desired state; Puppet owns package state after the first catalog.

## Direct egress

`network.egress` contains destination TCP grants, independent of HTTP/HTTPS proxy
policy. Entries have exactly one `host` or IPv4 `ip` and a nonempty unique `ports`
array (1–65535). `up` resolves all A records and replaces the complete policy;
resolution/apply failure blocks egress. IPv6 and external UDP grants are unsupported.

```yaml
network:
  egress:
    - host: repository.example.net
      ports: [443]
    - ip: 203.0.113.10
      ports: [443, 8443]
```

Named direct destinations enter generated `NO_PROXY`; applications choose DIRECT
or proxy themselves. See [networking](networking.md#one-gateway-one-direct-egress-policy)
for routing, revocation and privilege boundaries.

## Transparent TCP redirects

Use `network.redirects` to exercise production Puppet/Hiera endpoints against a
local service while preserving the original IP and port. For example, a PowerDNS
API compatibility service can receive these two endpoints:

```yaml
network:
  redirects:
    - from:
        ip: 192.0.2.8
        port: 8080
      to:
        service: api-compat
        port: 8081
    - from:
        ip: 192.0.2.9
        port: 8080
      to:
        service: api-compat
        port: 8081
```

Define `api-compat` under `containers.additional` using your test service image.
The example IPs are documentation addresses; substitute the endpoints used by your
Puppet code. `from` accepts only `ip` and `port`; `to` accepts only `service` and
`port`. Both ports are integer TCP ports from 1 through 65535. Sources must be exact
routable unicast IPv4 addresses outside the allocated workspace subnet. CIDRs,
wildcards, duplicate source pairs, UDP, IPv6 and external target addresses are
rejected. Service names are lowercase internal names, without `.empeira.internal`.
Enabled control-plane application services and additional services are supported;
nodes, the gateway, the browser UI relay and temporary bootstrap helpers are excluded.

Run `empeira up` after edits. It resolves owned service addresses, replaces gateway
policy and preserves existing nodes and the workspace network. Unknown/disabled
targets fail validation. Temporarily absent targets stay blocked until the owned
service is reconciled; unreachable target ports fail without contacting the external
endpoint, even when that endpoint also has an explicit egress grant.

Direct connections work from container/VM nodes, the Puppet server (including
catalog compilation) and internal services. HTTP methods, paths, headers and bodies
are unchanged. No DNS rewrite, egress grant, proxy exception or TLS termination is
created. Explicit proxy users connect to the proxy first and remain subject to its
allowlist; use the application's direct-connection settings when testing redirects,
for example `curl --noproxy '*' http://192.0.2.8:8080/test`.
See [redirect routing](networking.md#transparent-tcp-redirects) for connection
revocation and runtime boundaries.

## Control-plane images and provenance

[Built-in YAML defaults](../config/defaults.yaml) are the sole authoritative source
for default image repositories, software tags, immutable digests, agent versions
and release-package checksums. The server, database and PostgreSQL defaults use OCI
index digests covering both `linux/amd64` and `linux/arm64`. The runtime executes
`repository@sha256:...`; the accompanying tag describes the selected software.
Project configuration may independently replace each image. For example:

```yaml
images:
  server:
    reference: registry.example.org/custom/server:1
  puppetdb:
    repository: registry.example.org/custom/puppetdb
    tag: "1"
```

Server, PuppetDB and PostgreSQL images are independent. Image descriptors accept
`repository` plus `tag`, an optional `digest: sha256:...`, or a complete
`reference`. An explicit repository or tag clears an inherited default digest
unless the override also supplies a digest. A full reference replaces inherited
descriptor fields; combining it with repository, tag, digest or build in the same
configuration source is rejected. An explicitly supplied digest determines the
revision even if a descriptive tag is also supplied. Custom images need not be
digest-pinned. Validation is local and does not contact registries.
Compatibility of project-selected software is the project's responsibility.

OCI digests identify exact manifest/index bytes; descriptive tags identify software
releases. Default pin changes require verification of official registry indexes and
both platform manifests. Digest integrity does not establish publisher signatures.
Empeira does not promise verified signatures or attestations for its selected images.

The proxy is built locally from [resources/proxy/Containerfile](../resources/proxy/Containerfile).
Its reviewed base, Squid package version and Ubuntu snapshot are recorded in that recipe.
A signed current-archive package install bootstraps public CA trust, so the entire
build dependency closure is not byte-for-byte pinned. Recipe contents determine the
local image tag and verification label. Builds send only the generated Containerfile,
never control code or credentials. Changed recipes create new local image identities.
Existing tagged images are reused without automatic refresh. Package/image acquisition
uses engine networking during the build; running nodes remain isolated.

| Component | Selected version | Authoritative source / license |
| --- | --- | --- |
| OpenVox server | Default software tag and index digest | [OpenVoxProject](https://github.com/OpenVoxProject/container-openvoxserver), AGPL-3.0 container recipes |
| OpenVoxDB | Default software tag and index digest | [OpenVoxProject](https://github.com/OpenVoxProject/container-openvoxdb), AGPL-3.0 container recipes |
| PostgreSQL | Independent default software tag and index digest | [Docker Official Image](https://github.com/docker-library/postgres), MIT recipes and [PostgreSQL license](https://www.postgresql.org/about/licence/) |
| CoreDNS | Default software tag | [CoreDNS](https://github.com/coredns/coredns), Apache-2.0 |
| Squid | Reviewed package and snapshot in the local recipe | [Ubuntu snapshot service](https://snapshot.ubuntu.com/), Squid GPL-2.0-or-later and distribution package licenses |

Third-party image
contents retain their own licenses and notices. Empeira references and pulls these
public images and locally builds the proxy, but does not bundle or redistribute image contents. No Puppet Enterprise
artifact is used. Selecting a version is not a claim that an image has
no vulnerabilities; image refreshes need renewed upstream/security review.
Review [CoreDNS advisories](https://github.com/coredns/coredns/security/advisories)
and distribution security updates when selecting new artifacts. Locally built
helpers preserve rootless-compatible UID mappings and upstream notices.

The default control plane has six containers, or seven with the proxy, plus the
runtime's peer-network adapter. Requested limits
are 1536 MiB for the server (768 MiB JVM heap), 768 MiB for PuppetDB (256 MiB heap),
256 MiB for PostgreSQL, 64 MiB for DNS, 96 MiB for the database relay, 64 MiB
for the gateway and 128 MiB for Squid. The control-plane memory ceiling is about
2.7 GiB without the proxy, excluding the peer adapter and nodes. The server gets two CPUs and each
other service one. Actual idle use is lower and varies by provider and platform.
`up` automatically pulls missing remote images and builds missing recipe images.
Existing images are reused without any remote freshness check. Use `update images`
to explicitly check remote metadata and retrieve changed artifacts. A pinned image
is checked and acquired by its exact digest; updates never follow its descriptive
tag to a different build. Unchanged pins cause no pull. Changing an image reference
or digest changes its managed component fingerprint for selective reconciliation
on the next `up`. PostgreSQL version changes remain explicit; no database migration
is performed. No service is exposed on a host
port by default.

## Default image registry

```yaml
images:
  registry: null  # explicit docker.io for hostless repositories
```

To use a Docker Hub cache, set `images.registry: registry.example.net`
(or `registry.example.net:5000`). This optional value is a registry host,
with no scheme, path or credentials. Use an unambiguous host containing a dot,
`localhost`, or a host with a port. Repository paths remain unchanged:

| Repository | With `images.registry: registry.example.net` |
| --- | --- |
| `library/postgres` | `registry.example.net/library/postgres` |
| `linuxserver/chromium` | `registry.example.net/linuxserver/chromium` |
| `registry.example.org/team/server` | `registry.example.org/team/server` |
| `docker.io/library/postgres` | `docker.io/library/postgres` |

Without an override, hostless repositories explicitly resolve through `docker.io`;
Empeira never relies on runtime short-name search rules. A first path segment
containing `.` or `:`, or equal to `localhost`, is an explicit registry and stays
unchanged. Exact `reference` overrides also stay unchanged, including digest pins.
Tags and digest fields still work normally.

Docker Hub defaults for PostgreSQL, CoreDNS, Ubuntu, RockyLinux, AlmaLinux,
OracleLinux, the Go builder and Chromium are hostless. Explicit OpenVox, OpenVoxDB,
OpenVox View GHCR repositories remain direct. Reviewed Ruby/Ubuntu
build bases use the same resolver; resolved bases enter the recipe hash, so a
registry change gives those local images a new identity. Build dependencies are
explicit reserved `EMPEIRA_BASE_*` arguments, not arbitrary Dockerfile rewriting.

Docker/Podman supply their normal login, credential-helper and auth-file behavior
for metadata, pulls and builds. No registry credentials are stored in Empeira YAML
or state. A cache must expose the same repository paths and configured versions.
Registry authentication belongs to the selected container runtime, not to Empeira
configuration. Authenticate directly with the runtime you selected:

```bash
docker login registry.example.net
# Or, when using Podman:
podman login registry.example.net
```

Use `docker login docker.io` or `podman login docker.io` for Docker Hub, and the
actual explicit host for GHCR or another registry. Native credential helpers and
auth files remain owned by Docker/Podman. Empeira does not prompt for passwords,
copy auth files, persist tokens, or provide a `registry login` command. Never put
registry usernames, passwords, tokens, auth-file paths or credential structures in
either Empeira YAML file. Probable authentication/authorization failures include
the appropriate native login command; missing tags, network and TLS errors have
separate diagnostics and do not receive a blanket login suggestion.

## Browser and additional infrastructure services

```yaml
browser:
  start_url: "about:blank"
  image:
    repository: linuxserver/chromium
    tag: "latest"
containers:
  additional:
    - name: custom-service
      image:
        repository: registry.example.org/team/web-helper
        tag: "1.2.3"
      environment:
        KEY: "value"
      command: ["serve", "--port", "8080"]
```

The helper image above is a schema illustration; substitute your actual image/tag.
Both browser image fields may be overridden independently, including internal/private
registries. Authenticate using the selected runtime's normal registry tooling.
Browser-compatible images must provide the same HTTPS desktop UI on container port
3001, support `/config` as a disposable profile and operate without direct Internet.
No custom browser image is built by Empeira. Run `empeira up` before
`empeira browser`. The browser command validates the existing workspace and CoreDNS,
starts or reconciles only the disposable browser and its UI relay, and prints
`https://127.0.0.1:<dynamic-port>/`. It never starts or reconciles the configuration
server, PuppetDB, CoreDNS, gateways, additional services, or nodes. A missing or
stopped required workspace service produces an error that asks you to run
`empeira up`. The platform currently has no host-browser opener. The UI may take a
few seconds to initialize. Its default certificate is self-signed: accept it only
for the printed local endpoint. Browse `http://custom-service.empeira.internal:8080`
or node hostnames inside Chromium. No startup URL CLI argument or browser Internet
access is currently provided.

`browser.start_url` selects only the page initially opened in Chromium; it defaults
to `about:blank`. Supply a nonempty string without control characters. Empeira passes
the value unchanged as one `CHROME_CLI` environment value, without shell evaluation
or a network/HTTP readiness check. The destination must be reachable from the
isolated browser network. If the application is not ready when Chromium starts,
reload the page after it becomes available. Changing the value recreates an existing
browser on the next `empeira browser` or `up` reconciliation, using the new start page
and a fresh disposable profile.

Additional services automatically join `up`, `status`, `down`, and `destroy`.
Each has ownership labels, an inventory ID, a component fingerprint and the DNS name
`<name>.empeira.internal` (plus short name). Configuration changes recreate only the
affected service; removing a definition removes its owned container on the next `up`.
`down`/`destroy` also remove services no longer present in configuration. Writable
container layers are disposable; no helper data persistence is promised.

The only fields are `name`, `image.repository`, `image.tag`, optional `environment`
(string values), optional `command` (nonempty literal argument array), and optional
`configuration` (a generated YAML file, described below). Names are
unique lowercase DNS labels, up to 63 characters, and cannot collide with built-in
services, gateway identities or nodes. There are no host ports, volumes, privileged
options, devices, capabilities, arbitrary runtime arguments, dependency graphs,
restart policies or healthchecks. Status reports container state, not application
readiness. This is deliberately **not a Compose replacement**. Environment changes
are fingerprinted; inventory stores their hash rather than plaintext values. Runtime
administrators can still inspect container environments. Keep real secrets out of Git.

### Generated service configuration

An additional service can receive a configuration file directly from `.empeira.yaml`:

```yaml
containers:
  additional:
    - name: example-api
      image:
        repository: example/api
        tag: "1.0"
      configuration:
        target: /etc/example/config.yaml
        content:
          version: 1
          listen:
            port: 8080
```

This synthetic image is a schema example. Empeira serializes the parsed `content`
as YAML, generates a separate file for each service in the managed workspace, and
bind-mounts it **read-only** at `target`. No separate file in the control repository
is required. Maps, arrays, strings, integers, floats, booleans and `null` are supported,
including nested structures. Strings remain literal strings: Empeira adds no template,
environment-variable or other interpolation. YAML tags, anchors, aliases and Ruby
objects are rejected.

`target` must be an absolute file path, with nonempty path components containing only
letters, digits, `_`, `-` and `.`; `/`, trailing slashes, `.`/`..` components and unsafe
mount syntax are rejected. It must not overlap another managed mount, including the
runtime's `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf` files.

Changing `content` or `target` recreates the affected service on the next `up`.
Repeated `up` with unchanged configuration preserves the container and generated file.
`down` retains generated files; `destroy` removes them. Removing `configuration` or
the service removes its unused file after successful reconciliation. Host files are
readable by the container's service user but kept in a private workspace directory.
This is ordinary configuration storage, with no special handling for secrets; users
remain responsible for sensitive content. Omitting `configuration` preserves the
existing additional-service behavior.

### OpenVox View example

OpenVox View is the preferred example web viewer for OpenVoxDB/PuppetDB. It is an
ordinary `containers.additional` service, with no special Empeira orchestration.
Use this configuration to connect it to the internal HTTP API:

```yaml
browser:
  start_url: "http://openvoxview.empeira.internal:5000"

containers:
  additional:
    - name: openvoxview
      image:
        repository: ghcr.io/voxpupuli/openvoxview
        tag: "v1.8.0"
      environment:
        LISTEN: "0.0.0.0"
        PORT: "5000"
        PUPPETDB_HOST: "puppetdb.empeira.internal"
        PUPPETDB_PORT: "8080"
        PUPPETDB_TLS: "false"
```

The official image starts `/openvoxview` itself; no `command` is needed.
`LISTEN=0.0.0.0` is required because the application defaults to `localhost`.
Run `empeira up`, then `empeira browser`. Inside Chromium,
open `http://openvoxview.empeira.internal:5000`. No host port is published.

OpenVox View uses Empeira's internal PuppetDB HTTP relay at
`puppetdb.empeira.internal:8080`, with `PUPPETDB_TLS=false` and no TLS client
certificates. This API is intentionally unauthenticated inside the isolated network;
every node or service with access can use it. This is a disposable local test
configuration, not production security.

The optional Puppet CA interface is not enabled. It requires client key/certificate
material with `pp_cli_auth` and a CA certificate. The generic additional-service
schema intentionally offers no mounts for these files; the PuppetDB viewer needs
none of them. Leave `PUPPETCA_HOST` unset.
See the [upstream project](https://github.com/voxpupuli/openvoxview) and
[configuration reference](https://github.com/voxpupuli/openvoxview/blob/main/CONFIGURATION.md).

### Browser and example image provenance

- [LinuxServer Chromium](https://docs.linuxserver.io/images/docker-chromium/) is
  referenced as `linuxserver/chromium:latest`, resolved to Docker Hub by default.
  [Upstream packaging](https://github.com/linuxserver/docker-chromium) is GPL-3.0;
  Chromium is BSD-style with separately licensed components. Debian, Selkies and
  other bundled components retain their notices. Empeira does not redistribute
  image contents. The mutable `latest` tag is deliberate: `up` reuses the local
  image, while `update images` checks the selected platform manifest for changes.
- The upstream UI is **Selkies HTTPS on 3001**, with HTTP 3000 intended for reverse
  proxy use. Empeira publishes only HTTPS through a fixed TLS byte relay using the
  dedicated recipe-hashed Empeira relay image, with no custom browser image. Shared Docker/Podman
  adapters supply the same arguments; no privileged or unconfined mode is added.
  See [networking](networking.md) and [development](development.md) for smoke commands
  and actual platform validation scope.
- [Vox Pupuli OpenVox View](https://github.com/voxpupuli/openvoxview) uses
  [Apache-2.0](https://github.com/voxpupuli/openvoxview/blob/main/LICENSE), compatible
  with Empeira's AGPL-3.0-only license. The example references the official
  `ghcr.io/voxpupuli/openvoxview:v1.8.0` release image. The explicit GHCR repository is unaffected by `images.registry`.
  A release tag is not a digest lock. The upstream
  [container entrypoint](https://github.com/voxpupuli/openvoxview/blob/main/Containerfile.release)
  starts `/openvoxview` on port 5000. No upstream source, binary or image is bundled
  or redistributed by Empeira.

### Dedicated relay utility image

`images.relay.build: relay/Containerfile` selects the packaged recipe. The local
image is `localhost/empeira-relay:<SHA256-of-recipe>` and is verified by its recipe
label. Builds use an isolated temporary context containing only the recipe, never
control code or credentials. `images.relay.reference` may select an independently
prepared equivalent Ruby image. Browser relay scripts remain reviewed read-only
packaged mounts and their contents participate in service fingerprints.

The recipe uses the [Docker Official Ruby image](https://github.com/docker-library/ruby)
(MIT recipes), [Ruby](https://www.ruby-lang.org/en/about/license/) (Ruby/BSD terms)
and Alpine packages with their own notices. It adds no packages and runs as UID/GID
65534. It is built locally, not published or included in the gem as a binary.
A version tag is not an immutable digest; arm64 execution needs separate validation.

## Shared peer network internals

The selected container runtime and CLI host choose the peer backend automatically.
There are no user settings for subnet, VM IP/MAC, TAP, bridge, socket or adapter.
Application configuration uses logical names; additional services need no `ports`
or `expose` schema. `images.network_adapter_builder` selects the reviewed Go builder
image used by the existing recipe-hash image cache; Go is not a host prerequisite.
Node IP/MAC leases survive stop/start and are released on destroy. See
[networking](networking.md) for address pools, isolation and platform validation.
