# Troubleshooting

Start with `empeira config validate`, `empeira status` and `empeira node list`.
Status is read-only and reports unavailable engines or invalid inventory as
unknown/diagnostic states. Its successful exit means a report was produced, not
that infrastructure is healthy. `up` performs readiness checks.

## HTTP and transport errors

HTTP failures identify the operation, requested URL, actual status and server reason
phrase, followed by the available response. For example:

```text
Operation: Download agent package
URL: https://packages.example.org/apt/pool/agent.deb
HTTP status: 404 Not Found
Response:
  Package is unavailable
```

URLs retain their host and path; user information, sensitive query values, known
credentials, authorization headers and cookies are redacted. Multiline text and JSON
remain readable. HTML, truncation and unavailable/empty bodies are labelled; binary
bodies are omitted. Diagnostic output is limited to 8 KiB after redaction.

DNS, connection, timeout, TLS and proxy failures are reported as transport failures.
If no HTTP response was received, no status is invented. APT, DNF, Docker/Podman and
Git/r10k retain their native details; unavailable URL/status/body fields are identified
as unavailable separately. Empeira sends no extra requests for diagnosis. A 401 can
offer one agent-repository login in a TTY; CI uses both `EMPEIRA_AGENT_REPO_USERNAME`
and `EMPEIRA_AGENT_REPO_PASSWORD`. Rejected interactive and ENV logins are distinguished.
HTTP 403 does not trigger login, and HTTP 407 identifies proxy authentication. Registry
authentication continues to use native `docker login` / `podman login` and the reported
registry host; Empeira does not log into registries automatically.

APT helper credentials use literal `login` and `password` tokens in a temporary
0600 file under `/etc/apt/auth.conf.d`. APT treats surrounding quotes and added
backslashes as credential bytes, so Empeira does not add them. A successful login
rewrites this file before retrying the same metadata command. The host-side package
download reuses the credentials for the same HTTPS origin. APT's token format cannot
represent whitespace inside a credential value.

## KVM and QEMU

A present `/dev/kvm` is insufficient: the invoking user needs read/write access
and a working KVM API. Empeira reports device ownership, groups and capability
failures. If access is through the `kvm` group, add your user and start a fresh session:

```console
sudo usermod -aG kvm "$USER"
```

On WSL2, run `wsl.exe --shutdown` from Windows and reopen WSL after changing groups.
Do not change device permissions globally. Missing `/dev/kvm` or absent accelerator
support is not repaired by a group change. The QEMU build must support KVM/HVF for
the detected platform. Empeira refuses software emulation and does not provision
Windows-host QEMU automatically. See [installation](installation.md).

Missing `xorriso` prevents initial cloud-init seed creation. Install it with the
other VM prerequisites. Restarting an existing initialized VM does not require a
new seed build. ARM64 also needs the firmware reported by preflight.

## SSH login failures

For a VM, `node ssh` defaults to `empeira` and the existing managed private key,
including when bootstrap is incomplete. For containers, it uses the local user's
name and normal OpenSSH keys/agent/config. Neither path injects a replacement key
or provisions a login user. Verify your Puppet-created account,
authorized keys, home permissions, daemon, PAM and login profile. Use `--user` and
`--identity` independently when appropriate:

```console
empeira node ssh host1 --user deploy --identity ~/.ssh/test_ed25519
empeira node shell host1
```

If SSH reports `Too many authentication failures`, your agent may offer too many
keys before the intended one. For containers, select the identity in your normal
OpenSSH `Host` configuration and set `IdentitiesOnly yes` there when needed. VM
access selects its managed or explicit identity and disables password authentication.

For a container, shell is runtime exec. For a VM, it is the serial console and
works with SSH stopped. Press Enter, then use the current console credentials.
The initial default is `root` / `empeira`, unless disabled/overridden or changed by
Puppet. **Ctrl-] detaches**. Empeira does not reset credentials to repair a failed login.
Stopped nodes need `node start`. Investigate changed SSH host keys instead of
turning off checking. Destroy/recreate removes a disposable node's private known-hosts entry.

VM sessions release the workspace mutation lock. Status and independent workspace
operations remain available, and multiple VM SSH sessions may coexist. Stop, destroy
or restart of that same VM conflicts with the shared instance guard: detach with
**Ctrl-]** for console sessions, or exit SSH, then retry. Do not delete lock files.

## Proxy destination denied

Run `empeira proxy show HOSTNAME` and check every matching rule. Verify the node
exists in the workspace, `proxy.enabled` is true, and `up` has reconciled the
configuration and current node addresses. Allowed DNS destinations may resolve to
private or reserved IP addresses; only HTTP port 80 and HTTPS CONNECT port 443 are
permitted. After updating Empeira, run `empeira up` to replace a proxy still using
the previous IP restrictions. Managed bootstrap access retains its own destination
restrictions and does not grant normal access afterward. See [proxy](proxy.md).

## Hiera and EYAML

`config show` includes `effective_hiera_mounts`. A skipped optional source is
reported during `up`; mount it locally or correct the source path, then run `up`
again. Set `required: true` when absence must stop startup. Invalid targets,
collisions, symlink escapes and known modulepath exclusions are errors even for
optional mounts. Existing mounted data changes are live without a restart.

When EYAML is enabled, both key paths must resolve to readable regular PEM files.
Relative paths are resolved against the selected canonical control repository.
Check engine visibility/UID mapping and the paths in `hiera.yaml`, without printing
private material. See [Hiera and EYAML](hiera-and-eyaml.md).

## Retained, missing or stale resources

If agent installation reports an unavailable package version, compare
`agent.version` and the configured repository `suffix` with the versions
published by that source. The retained node can be inspected with `node shell`.
For `method: package`, use the complete installed package version and verify
its URL and SHA-256. A checksum mismatch stops before package installation.
Valid agent-cache hits need no network access or credentials. On a cache miss,
a damaged artifact or with caching disabled, `401 Unauthorized` calls for both
`EMPEIRA_AGENT_REPO_USERNAME` and `EMPEIRA_AGENT_REPO_PASSWORD`; `403 Forbidden`
means access is denied and `404 Not Found` means a source or package is missing.
A signature error calls
for checking the configured signing key or RPM signature. Credentials do not
belong in YAML. Failed APT/DNF restoration retains the node and prevents the
first Puppet run and subsequent `node start` or `node puppet` operations. Existing
release packages are rejected before changes; use a clean base image or a signed
custom source. Protected DNF release-RPM repositories are unsupported; configure
`agent.install.dnf` instead.

If node creation fails during key preparation, verify that the selected agent
package was installed and provides `/opt/puppetlabs/bin/puppet` and
`/opt/puppetlabs/puppet/bin/ruby`. Keep replacement agents out of
`bootstrap.packages`: configure `agent.package`, `agent.version` and
`agent.install` instead, then destroy and recreate the incomplete node.
The agent choice does not change server or database images.

A failed bootstrap retains the container or VM and hostname for diagnosis:

```console
empeira node logs vm1
empeira node ssh vm1
empeira node shell vm1
empeira node destroy vm1
empeira node run vm1 --provider vm
```

APT cleanup errors now identify the failed archive or removal operation, exit code,
timeout and sanitized native output. A guest failure is distinct from an SSH
transport failure with unknown completion. A readable backup that can be removed
manually does not establish the earlier SSH outcome. The already verified backup
removal is retried once only for recognizable transient SSH connection errors.
Permission, host-key and authentication errors, command timeouts and persistent failures
remain fatal. Successful manual cleanup alone does not mark an incomplete node as
provisioned or permit Puppet; correct the reported cause and recreate the node.

Incomplete nodes remain available for diagnostics but cannot start or run Puppet.
Destroy and recreate them after correcting the source of the failure. Missing or corrupt
pinned base images require restoring the exact cached image before an existing
overlay can resume. Image changes never replace node state automatically.
Ownership conflicts or changed runtime IDs require inspection; deterministic names
are insufficient to adopt/delete resources. Never delete inventory or the stable
mutation lock file to bypass a failure. Unknown state schemas fail closed.

`down` removes services/networks but retains CA and database volumes. Existing nodes,
even stopped ones, must be destroyed first. `destroy` permanently removes all owned
workspace nodes, infrastructure and retained CA/database data without a prompt.
If `up` reports that a managed service exited after start, inspect its container logs
using the runtime command printed in the error. A route-helper failure can otherwise
hide an earlier service exit; `status` shows which service stopped.
`destroy` can also run when `.empeira.yaml` or user configuration is invalid. It uses
the validated inventory to select the owning runtime and removes only owned resources.
Keep the project marker file and valid inventory in place for this recovery path.
It preserves the control repository, module directory and native caches so a subsequent `up` can reuse
unchanged Puppetfile modules. Missing retained volumes or database credentials
are not permission to initialize empty replacements. Preserve state and volumes
together during recovery. See [architecture](architecture.md#persistent-state-and-ownership).

## Project marker and browser

“An Empeira Git project is required” means the current directory is outside a Git
worktree, or Git cannot run. Enter your control repository and check
`git rev-parse --show-toplevel`. A missing-marker error prints the canonical root,
exact `.empeira.yaml` path and shell-safe `touch` command. An empty marker is valid;
placing it in a subdirectory does not opt in the root. `--project` is not supported.

`empeira browser` prints a dynamic loopback HTTPS URL. The default UI has a self-signed
certificate and may take a few seconds to initialize. Open internal URLs in that
Chromium desktop, not directly in the host browser. External websites failing is
expected: the browser has no Internet grant. `status` shows Browser and Browser-ui;
`up` reconciles an existing browser, and `down` removes it and its disposable profile.
Run `empeira up` before the first browser request. The browser command does not start
or reconcile stopped workspace infrastructure. If it reports a missing workspace,
network, or CoreDNS service, restore the control plane with `empeira up` and retry.
`browser.start_url` defaults to `about:blank` and is not checked for reachability.
For an internal application that starts later, simply reload the page in Chromium.
If ownership or loopback/network checks fail, investigate the runtime resource rather
than attaching an unrestricted network or publishing services publicly. Browser-to-VM
URLs use the VM hostname and application port directly. Check VM network health,
CoreDNS records and whether the guest application listens on its peer interface.

OpenVox View should use `PUPPETDB_HOST=puppetdb.empeira.internal`,
`PUPPETDB_PORT=8080`, and `PUPPETDB_TLS=false`. Check internal DNS and PuppetDB's
HTTP query readiness if it cannot load data. No client TLS credentials are needed.
Do not publish PuppetDB to the host: its HTTP API is intentionally unauthenticated
within the disposable isolated network.
The configuration server uses the HTTPS relay on port 8081 with a workspace
CA-issued server certificate. This is required by the PuppetDB terminus; check
the relay and backend separately if catalogs or reports fail. The backend itself
listens only on HTTP port 8080.

The browser relay builds `resources/relay/Containerfile` locally. On build errors,
check the selected runtime's registry access and the configured relay recipe/image;
changing the Puppet/OpenVox server image is not a relay dependency fix.

## Shared peer network

Unsupported inventory/definition revisions require explicit recovery or recreation.
Preserve state while investigating ownership errors; never delete live channel
directories, force-remove attached networks, reset Podman Machine or kill processes
by name. No automatic migration is provided.

Native rootless Podman requires writable TUN and KVM inside
`podman unshare --rootless-netns`, iproute2, Netavark and disabled forwarding on the
owned bridge. Docker requires its supported isolated bridge mode. A packet helper
checksum, network, capability or recorded-ID mismatch fails closed. A live QEMU or
channel with an unavailable control socket must be investigated before retrying.

On macOS, select exactly one running rootless Podman Machine and its matching default
connection. Share the canonical Empeira state path with that machine: the exported
helper must have the same SHA-256 from both hosts. No rootful fallback is available.
Subnet exhaustion means known host/VPN or runtime routes cover all candidates;
inspect those routes instead of disabling overlap checks. IPv6 peer networking is
not supported.

## Artifact updates

`update modules` and `update images` do not start or reconcile infrastructure. Image
changes take effect during the next `empeira up`. Module updates write directly into
`modules.path` and can be visible to a running server immediately. `up` never synchronizes modules; missing modules fail before runtime mutation with
`Run: empeira update modules`. Missing images are acquired automatically; existing
images are reused without remote checks.
Failed explicit updates may leave partially changed module files; fix the cause and
rerun the update. Existing plausible modules are usable without a freshness check. Diagnose Forge, registry, version/ref, authentication and normal
host/container connectivity errors; changing the workspace proxy allowlist does
not repair update-plane connectivity. User proxy settings and runtime registry
credentials apply. Git uses the invoking user's normal SSH identity and configuration.

Image updates preserve the native Docker/Podman buildcache (`build --pull`, without
`--no-cache`) and select the configured default plus workspace-used container node
variants. Native remote metadata checks have a 30-second budget (Podman may need
up to five more seconds for local temporary-manifest cleanup). Authentication,
unsupported/malformed metadata or timeout errors identify the image and filtered
diagnostic; no full pull is attempted as a fallback. Docker/Podman must support their
native manifest commands. An old index digest may need a native immutable-reference
lookup for platform comparison; a registry that has deleted that manifest can prevent
the comparison. Fix registry access or explicitly remove only the affected unused
local artifact before retrying. Builds and pulls have a 600-second timeout. A timed-out CLI process group
is killed and reaped, its temporary build context is removed, and filtered buffered
diagnostics identify the affected image. Successful tool logs remain hidden.

Update helpers are removed after completion where the engine is reachable. If an
engine stops responding during cleanup, restore access and inspect the reported
update-helper failure before removing anything; names alone do not establish
ownership. `self-update` and `update all` remain unavailable until release package
replacement is implemented. Image updates are not atomic across the full catalog;
earlier successful pulls/builds remain after a later failure.

## User preferences and registry authentication

`config show` includes effective `runtime.container_engine` and `images.registry`
after optional `~/.empeira.yaml` preferences. Only those two keys are allowed there;
move project behavior into the control repository rather than adding user-level
server, network or service overrides. Invalid user YAML fails with its file and
configuration path. The file is optional; absence is not an error.

For likely registry authentication/authorization failures (401/403, unauthorized,
authentication required, access denied or insufficient scope), Empeira prints the
native login command for the resolved registry, for example
`docker login registry.example.net` or `podman login ghcr.io`. Authenticate
and verify repository permissions, then retry the original Empeira command. A login
cannot grant permissions your account does not have. Runtime credential helpers and
auth files are used directly; Empeira never manages registry credentials.

`manifest unknown`, `name unknown` and missing-image errors point to the repository
or tag. Timeouts, refused connections and DNS failures require network diagnosis;
certificate/x509 failures require runtime CA trust diagnosis. These errors do not
produce login advice. Sanitized native diagnostics are retained for all categories;
metadata failures never fall back to a full pull.

## Workspace gateway and direct egress

`status` reports Gateway/DNS/Proxy readiness and overall Workspace network health.
After an egress edit or DNS change, run `empeira up`; nodes keep their identities.
A failed hostname lookup leaves egress blocked. Check the host/corporate resolver
and every A record first. An IPv6-only destination is unsupported, not silently allowed.

For DIRECT traffic, inspect `network.egress`: exactly one host/IP and the actual
TCP port must be allowed. `NO_PROXY` is application selection, not authorization.
No proxy fallback occurs. A denied SYN normally times out; Empeira cannot infer
from that timeout alone whether a remote service, route or firewall caused it.
`Network is unreachable` instead suggests a missing node default route; rerun `up`
to repair managed container routes and inspect the VM workspace NIC gateway.

Gateway firewall drift or disabled forwarding is reported separately by the
readiness probe. Failed apply stops/blocks the gateway; never attach a node to an
external runtime network as a workaround. Docker workspace bridge attachment
errors require an accessible Linux-engine host namespace and an identifiable
iptables backend. The helper changes only owned bridge rules. Do not disable the
host firewall globally. Check Docker Desktop host-network restrictions separately.
Proxy errors require checking Squid source bindings and `proxy.global`/`proxy.rules`,
not adding unrelated direct grants. Corporate DNS still follows host discovery;
IPv6-only upstreams must be replaced with reachable IPv4 resolvers for this backend.
