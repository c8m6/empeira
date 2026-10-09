# Nodes

Create nodes imperatively after `empeira up`; named nodes do not belong in
`.empeira.yaml`. `node run HOSTNAME` defaults to `container`; select `--provider vm` for a VM.
Existing-node commands use the provider recorded in workspace state.

```console
empeira node run host1 --provider container --os ubuntu --version 24.04
empeira node run vm1 --provider vm --memory 2048 --cpus 2
empeira node list
empeira node puppet host1
empeira node logs host1
empeira node shell host1
empeira node ssh host1
empeira node stop host1
empeira node start host1
empeira node destroy host1
```

The default node is Ubuntu 24.04, 1024 MiB, and two CPUs. External traffic requires
an explicit TCP egress rule or an allowlisted proxy policy. If the workspace proxy
is enabled, the node automatically gets
controlled HTTP/HTTPS access to destinations allowed by its proxy policy.
Hostname/certname is unique across both providers within a workspace. Names are
normalized to lowercase; service names are reserved. Another checkout may reuse
the same hostname. Before the first Puppet run, Empeira installs
`/etc/puppetlabs/facter/facts.d/empeira.yaml` with exactly one structured fact:

```yaml
empeira:
  provider: container
```

VM nodes use `provider: vm`. Both providers verify this readable external fact before
enrollment; Facter's normal `facts.virtual` remains unchanged.
Creation reserves identity atomically, including failed attempts.
`stop` preserves the disk and identity, `start` resumes them, and `destroy` permanently
removes the owned resource and its specific CA identity before releasing the name.
Puppet exit codes 0 and 2 succeed. A failed catalog retains diagnostic state.

Puppet output uses ANSI colors when both stdout and stderr are terminals. Redirecting
either stream, setting `CI`, using `TERM=dumb`, or setting `NO_COLOR` disables Puppet
colors. Container and VM runs use the same policy. The progress display is suspended
while Puppet streams its output and resumes on a fresh line afterward.

`node list` reports observed runtime state and the last Puppet result without
waiting for guest readiness. `node puppet` runs another catalog after local code
or Hiera edits. `node logs` streams runtime output for containers and the serial
log for VMs. Node deletion needs the reachable workspace CA after enrollment;
restore the control plane with `up` if it was stopped externally. Whole-workspace
`destroy` removes the CA together with nodes.

## Environment cache and live code

Managed servers default to `environment_timeout = unlimited`. Before `up`, node
start, or an Empeira-managed Puppet run finishes preparing the environment, Empeira
compares a SHA-256 snapshot of the live control repository, configured module
directory, external Hiera sources and explicit server mounts with its last successful
checkpoint. Uncommitted edits, new files, deletions and symlinked inputs are included;
Git metadata and Empeira's state/cache directories are excluded. This deliberately
includes all readable files in those source trees because Puppet functions and Hiera
can read arbitrary repository data. Large artifact directories increase scan cost.

Changed inputs invalidate only `server.environment` through the authenticated Puppet
Server environment-cache API. An unchanged second run keeps loaded environment code.
The checkpoint is saved in the existing workspace inventory only after a successful
API response, under the normal mutation lock. A failed scan or invalidation stops
the Puppet run. Editing code does not restart the server. Module updates remain
independent of the runtime; the next `up` or node Puppet run observes their changes.

This caches loaded code, not compiled catalogs: every normal Puppet run requests a
fresh catalog, and Empeira does not enable `use_cached_catalog`. A repository's own
`environment.conf` can override the server timeout. Direct/manual agent runs do not
invoke Empeira's change detection; run `empeira up` after edits before using them.
Avoid concurrent edits during a catalog run. `node start` resumes the node; it does
not itself invoke Puppet. Puppet services enabled by the tested catalog may run on
startup independently.

## Distribution package sources

The reviewed Ubuntu container recipes retain the upstream distribution sources.
Ubuntu 24.04 uses `/etc/apt/sources.list.d/ubuntu.sources` (deb822); older images may
use `/etc/apt/sources.list`. VM Cloud-Init leaves the base image's APT configuration
untouched. It does not generate archive, security, ports, or internal repository
entries.

For either agent installation method, Empeira handles `bootstrap.packages` against
the base image's sources first. A disposable host-side helper resolves the selected
agent source using the target OS and architecture. The agent artifact is acquired
and normally reused from the shared user cache, then uploaded through the existing
container or VM transport and installed locally with APT/DNF. Agent repositories
and repository credentials never need to be installed on the node. Missing
dependencies may still use its unchanged base repositories through the short-lived
bootstrap proxy; cached artifacts do not guarantee offline installation.

Empeira archives `/etc/apt` for Ubuntu or `/etc/yum.repos.d` and `/etc/dnf` for RPM
guests. Uploaded packages, temporary signing keys and proxy configuration are
removed, and the archive is restored and verified before bootstrap access is
removed, certificate enrollment completes and the first catalog runs. A failure
retains the incomplete node for diagnostics and prevents Puppet. Already
provisioned nodes are not bootstrapped again by `up` or `node start`. See
[agent sources and caching](configuration.md#agent-sources-and-shared-package-cache)
for generic sources, version resolution, optional verification and HTTP login.

After restoration and before the first catalog, both node providers perform the same
read-only check for active Ubuntu/Debian distribution APT sources. Legacy `.list`
and deb822 `.sources` files are accepted. A missing/disabled source fails with an
actionable error and retains the node for inspection. No source is rewritten on
`up` or `node start`: repository ownership after bootstrap belongs to the tested
Puppet code. If a catalog purges unmanaged sources without declaring replacements,
the control repository must fix that classification. Check both source locations;
an empty `sources.list.d` alone does not prove that APT has no sources.

Source configuration does not grant egress. Managed VM agent installation uses the
temporary authenticated bootstrap proxy with reviewed base-distribution destinations.
Agent acquisition uses host/helper access, outside the isolated node network. After
bootstrap, normal access depends on the workspace proxy. Interactive `apt-get update`
or package resources need an enabled proxy and an explicit destination policy as described in
[networking](networking.md). Empeira never grants unrestricted Internet access to
repair package sources.

## Shell and SSH

| Provider | `node shell` | `node ssh` |
| --- | --- | --- |
| Container | Runtime exec into `/bin/bash` | Real OpenSSH to the guest daemon |
| VM | Direct QEMU serial console | Real OpenSSH to the guest daemon |

Direct access is useful for repair even when SSH, PAM, login profiles or network
configuration is broken. SSH exercises the login path that Puppet actually configures.
Neither access command starts a stopped node implicitly. Use `node start` first.
Both retain normal interactive output without a progress overlay.

The default SSH username is the local execution user's account name. On WSL2 this
is the Linux account. Default keys, `ssh-agent` and normal OpenSSH configuration
remain available; Empeira does not force a generated login identity. Configure the
user, authorized keys and daemon through your Puppet code or guest configuration.
An authentication failure remains an SSH failure, with the client's output and
exit status. It never creates a login user, injects keys, or falls back to exec.

```console
empeira node ssh host1
empeira node ssh host1 --user deploy
empeira node ssh host1 --identity ~/.ssh/test_ed25519
empeira node ssh host1 --user deploy --identity ~/.ssh/test_ed25519
```

`--user` and `--identity` are independent. The logical hostname can select a `Host`
section in SSH configuration. Empeira fixes the host, port and transport to the owned
node, disables connection sharing and forwarding, and uses a private per-node
`known_hosts` file with `accept-new` checking. User settings cannot redirect the
connection through another proxy or jump host. Keys in the developer's SSH agent
remain usable. Host-key changes fail until investigated; disposable host entries
are removed with the node and do not pollute `~/.ssh/known_hosts`.

Podman publishes SSH on a verified dynamic loopback port. Docker's internal bridge
does not activate published ports, so OpenSSH uses a runtime exec byte tunnel to
port 22 inside the ownership-checked container. This still carries real SSH traffic.
VM SSH uses a restricted management NIC and QEMU's loopback forward. Native rootless
Podman accesses it through a namespace-scoped byte tunnel. Application traffic, DNS
and Puppet use the separate peer NIC directly.

Packaged container images install and start OpenSSH, generating host keys at first
startup. They enable public-key login with `.ssh/authorized_keys`; password and
keyboard-interactive login are initially disabled. They do not provision developer
accounts or authorized keys. Puppet may manage the daemon and authentication policy.
Custom node images must provide the corresponding startup and package-manager contract.

The VM technical user `empeira` and its private generated management key are separate
from user-facing SSH. Empeira uses them to install the agent, enroll certificates
and run Puppet. They are not a fallback login for `node ssh`.

## VM console recovery

Each VM has a private Unix-domain serial socket created by its QEMU process.
`node shell vm1` attaches to that existing endpoint without starting another QEMU.
Press Enter to obtain a prompt. **Ctrl-] detaches** and leaves the VM running.
Local terminal mode is restored after detach, EOF or errors. Serial access carries
terminal bytes rather than SSH window-size negotiation; use `stty rows N cols N`
in the guest when a full-screen program needs different dimensions.

The initial recovery login is `root` with password `empeira`:

```yaml
vm:
  console:
    root_password: empeira
```

Set a different string for another initial password, or `null` to leave root password
configuration to the image/Puppet. The value applies once during cloud-init, only
to console recovery. It does not enable SSH password authentication. Puppet may
subsequently change or lock root, and Empeira does not restore this password on
`start`, `up`, or later Puppet runs. Keep real overrides outside version control.

Configuration display redacts the password. It is absent from node inventory,
image metadata and infrastructure fingerprints. Seed-generation files are private
and removed after ISO creation. After initial cloud-init, Empeira rewrites the
host seed without the password and removes guest cloud-init credential payloads.
The console socket is private to the local user, has a short macOS-compatible path,
and is separated by workspace and node identity. Node destruction removes it.

## VM images and bootstrap

Install the [VM prerequisites](installation.md#vm-prerequisites) before creating a
VM. Capability detection selects KVM or HVF; software emulation is never automatic.
Preflight checks commands, acceleration, image metadata, scripts, package destinations
and control-plane readiness before downloads or node reservation.

Ubuntu 22.04/24.04 cloud images and Rocky 8/9 GenericCloud images come directly from
[Ubuntu](https://cloud-images.ubuntu.com/releases/) and
[Rocky Linux](https://dl.rockylinux.org/pub/rocky/). Availability depends on architecture.
SHA-256 manifests are fetched over HTTPS and complete images verified before caching.
The immutable cache identity includes distribution, version, architecture, source,
revision and checksum. Each VM has a QCOW2 overlay pinned to its original base.
Destroying a node removes its overlay and seed, preserving the shared base cache.

Cloud-init prepares identity, the management account, DNS adapter, console recovery
and optional project scripts. Managed installation then installs the selected public
Puppet/OpenVox agent through separate bootstrap proxy access. Normal proxy rules are
not needed for standard installation. Bootstrap access ends
when installation completes or fails. See [proxy policy](proxy.md).

Incomplete bootstrap retains the VM for `node logs`, `node shell`, inspection and
explicit `node destroy`. An incomplete VM must be destroyed and recreated before
it can be started as a ready node. Preflight failures retain no new node.

## Node images and fidelity

| OS catalog key | Versions | Build source |
| --- | --- | --- |
| `ubuntu` | `22.04`, `24.04` | Docker Official Ubuntu images |
| `rocky` | `8`, `9` | Rocky Linux project images |
| `almalinux` | `8`, `9` | Docker Official AlmaLinux images |
| `oraclelinux` | `8` | Docker Official Oracle Linux image |

`images.nodes.OS.VERSION` defines the base repository/tag, packaged build recipe and
allowed `architectures` (`amd64`, `arm64`). The engine architecture is selected
and the resulting image architecture checked; emulation is never automatic. A
full `reference` overrides building and must provide the documented shell,
init mode and networking tools. Agent installation is controlled independently
by `agent.install` after the node starts.

The project-owned [node recipes](../resources/nodes) add SSH and diagnostic
tools but contain no agent package, source credential or Empeira PATH override.
The default bootstrap installs the agent version in [built-in defaults](../config/defaults.yaml) through a reviewed,
SHA-256-pinned release package and native signed APT/DNF repository. Custom
repository sources or direct verified `.deb`/`.rpm` packages can be configured
under `agent.install`; the selected server and PuppetDB images do not change.
Source configuration is restored and bootstrap access removed before certificate
enrollment and the first Puppet run. Container images remain in the selected
runtime cache; VM base images use the separate checksum-addressed cache. No
agent packages or images are bundled in Empeira releases.

Runtime tests report the selected OS, init mode and architecture. Systemd and HVF
need their own capable hosts; amd64 tests do not establish arm64 execution.

The Ubuntu base `docker.io/library/ubuntu` is the [official image maintained by
Canonical](https://hub.docker.com/_/ubuntu); `library` is Docker Hub's official-image
namespace. The minimal upstream image is extended with `sudo`, `locate` and
`updatedb` for catalogs that expect these commands before package management runs.
Ubuntu uses `plocate`; the RPM recipe uses `mlocate`. Puppet remains responsible for
application packages and sudo policy. No additional sudo grants are installed.
Run `updatedb` after filesystem changes before relying on `locate` results; process
mode does not run the distribution's timer or cron daemon. Existing nodes require
explicit destroy/recreate to receive changed recipe contents. VM images retain
their upstream package selection.

These tools come from the distribution's signed repositories, with package license
notices retained: [sudo](https://github.com/sudo-project/sudo/blob/main/LICENSE.md)
uses permissive licenses; [plocate](https://plocate.sesse.net/) and
[mlocate](https://git.almalinux.org/rpms/mlocate) use GPLv2 licenses. They run as
separate distribution programs and are not linked into Empeira's AGPL code.
Review distribution security updates when rebuilding. Cached images do not acquire
package updates automatically.

Default `process` mode uses the runtime's small init and a persistent sleeping process.
The images contain systemd, but it is not PID 1 in that mode. Explicit
`node_defaults.init: systemd` requires Podman with cgroup v2. Unsupported runtimes fail
instead of enabling privileged mode or mounting host cgroups. Systemd mode requires a separate cgroup-v2 integration host. Container catalogs requiring unavailable
kernel, boot or device functionality fail naturally. VM nodes provide higher
fidelity when host acceleration and the required QEMU tools are available. The
provider fact must not be used to hide container limitations.

Distribution contents retain their package licenses. Sources include
[Ubuntu](https://hub.docker.com/_/ubuntu),
[Rocky Linux](https://github.com/rocky-linux/sig-cloud-instance-images),
[AlmaLinux](https://github.com/AlmaLinux/docker-images), and
[Oracle Linux](https://github.com/oracle/container-images).
The public [OpenVox agent](https://github.com/OpenVoxProject/openvox) and optional
[Puppet agent](https://github.com/puppetlabs/puppet-agent) use open-source components,
including Apache-2.0 Puppet/OpenVox code. No RHEL or Puppet Enterprise artifact is used.

A configured image change marks existing nodes stale; it never replaces their writable
state automatically. Destroy/recreate them explicitly. Changing or replacing CoreDNS
with retained nodes is refused because their resolver bindings must remain valid.

## Configuration and stale resources

Workspace `mocks.commands` provides generic executable command stubs for Puppet
tests on both node providers. See [command mock configuration](configuration.md#command-mocks-on-test-nodes)
for echo and script-forwarding examples and mandatory exit-code selection.

Mocks are applied before each managed Puppet invocation and during `node start`,
including an already running node. `empeira up` reconciles mocks on running nodes
without restarting them or running Puppet. Stopped nodes reconcile on their next
start. A configured mock replaces an existing file or symlink at its target and
is restored if another program overwrites it. Removed entries delete only
unchanged, ownership-verified stubs. Destroying a node removes its mocks with
the owned container or VM disk.

Managed container nodes must have the agent Ruby at
`/opt/puppetlabs/puppet/bin/ruby` after agent bootstrap and before mocks can
be reconciled. If this interpreter is missing, inspect the retained node and
its image. Both providers record `provisioned: false` until package cleanup,
bootstrap access removal, final network/configuration and certificate enrollment
have succeeded. Failed nodes remain `incomplete` and accessible through shell/logs,
but `node start`, `node puppet` and mock reconciliation are blocked. After diagnosis,
destroy and recreate the node. A failed first catalog can be retried once provisioning
is complete. `up` does not install the agent into an existing node.

Unsupported inventory schemas fail closed without automatic migration.

Existing-node commands still validate the full project configuration. Invalid
provisioning settings can block shell, SSH, logs or cleanup until corrected.
Ownership, inventory and version checks remain active on access operations.
A stale image does not cause automatic replacement. Preserve required data and
explicitly destroy/recreate a node when changing its image definition.

OpenSSH packages come from the selected distribution repositories. Their
[upstream license notices](https://github.com/openssh/openssh-portable/blob/master/LICENCE)
remain in the installed packages; the permissive OpenSSH licenses are compatible
with project-owned AGPL code. Consult [OpenSSH security advisories](https://www.openssh.com/security.html)
and distribution updates when refreshing images. `update images` checks native base-image manifest metadata and skips unchanged
recipes/resources/bases. Required builds use `--pull` and retain native cached
package-install layers; unchanged inputs do not reinstall packages. Updated bases or recipes cause dependent layers
to rebuild. The Ruby dependency audit does not audit OS packages.

A stopped VM resumes through visible retained-storage, network, QEMU-start and SSH
readiness milestones. It keeps its existing base/overlay and does not rerun Puppet
automatically. Container/VM creation and destroy retain their named workflow stages;
only module and image updates use homogeneous completed/total counts.

## Peer network lifetime

Container and VM nodes are direct IPv4 peers. Use their logical DNS names from
other nodes, additional services and Chromium; arbitrary TCP/UDP requires no port
publication. Stop/start preserves the instance's IP, MAC and DNS record. Destroy
releases the lease and removes the record and owned transport resources. Recreating
a name does not promise the previous IP or MAC. VM status includes network health:
`running`, `reserved` for a stopped instance, or `degraded` when its adapter is missing.
