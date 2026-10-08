# Project conventions

These conventions apply to all repository work unless an explicit task instruction
overrides them. Prefer existing architecture and helpers; keep changes focused.

## Purpose and scope

Empeira means Ephemeral Manifest Playground for Exploring Infrastructure, Roles &
Automation. It operates disposable local Puppet/OpenVox test infrastructure.

In scope: servers, PuppetDB/PostgreSQL, container/VM nodes, DNS, isolation, controlled
egress, Hiera/EYAML, shell/SSH, an internal browser, small infrastructure services
and image/cache lifecycle. Generic DevOps utilities, converters, Git hooks/helpers,
IDE setup and documentation generators are out of scope. `containers.additional`
must not become a Compose replacement.

The product is Empeira, the CLI is `empeira`, and the project marker is
`.empeira.yaml`. Documentation and configuration-example comments are English.
Preserve literal CLI labels and keys. Do not create planning, scratch, progress or
temporary Markdown files unless requested; project documentation and this file
are exempt. Update affected documentation with every change.

## Licensing and dependencies

Project-owned code and documentation use `AGPL-3.0-only`. Preserve licensing and
third-party attribution. Before introducing dependencies or third-party material,
check provenance, compatibility, maintenance and known vulnerabilities. Prefer
Ruby's standard library and small dependencies; report uncertainty explicitly.
Never commit, bundle, redistribute or include proprietary Puppet Enterprise
software in release artifacts. Users own licensing and compatibility of their
custom images and packages.

## Platforms and process execution

Support native Linux, native macOS and Linux inside WSL2. Native Windows execution
is unsupported. Keep core code portable: use `Pathname`, `Dir.home`, `Dir.tmpdir`,
`Tempfile` and argument arrays. Do not hard-code usernames, Linux home paths,
temporary directories or executable locations, or depend on GNU-only behavior
where Ruby provides a portable equivalent. OS-specific code belongs in dedicated
platform adapters. WSL mirrored networking and nested KVM are not baseline
requirements. Windows-host interoperability requires a dedicated concrete adapter.

All application process execution uses the central `Execution::Runner`; do not
scatter `system`, backticks, `%x`, `Open3` or shell command strings. Use explicit
executable, arguments, environment, directory, timeout and streaming/capture modes.
Shell semantics require an explicit need. Timeouts and interrupts reap owned
process groups. Redact secrets before logging or truncating diagnostics. Interactive
output suspends progress rendering and restores terminal state.

## Architecture and software

Keep Core, Configuration, CLI, Execution, Platform, Container Runtime, Server
Runtime, Node Provider, VM Engine and Image Source boundaries explicit. Provider
selection belongs in factories and adapters, never distributed conditionals.
Help, validation and completion expose registry names without constructing providers.

- Podman is the default container runtime; Docker is also supported. Preserve
  rootless Podman and shared provider/lifecycle contracts.
- Public node providers are `container` and `vm`; `node run` defaults to container.
  QEMU is an implementation backend, not a public provider.
- Select KVM/HVF from real capabilities. Fail clearly without acceleration; never
  silently use TCG. Complete VM preflight before downloads, cache writes, node
  reservation, overlays, seeds, ports, certificates, helpers or launch.
- VM base images are immutable, checksum-verified and cached; each node uses a
  QCOW2 overlay pinned to its original revision. Prefer authoritative upstream
  sources and do not redistribute images unnecessarily.
- OpenVox Server, OpenVoxDB, PostgreSQL and OpenVox Agent are defaults. OCI images
  are independently configurable; agent package/version/source selection is
  separate. Maintain one control-plane lifecycle and explicit validated server and
  database runtime contracts. Do not classify custom images or introduce selectable
  server providers. Prefer standard Puppet configuration mounts to image patching.
- Official references, versions, index digests and release checksums belong solely
  in `config/defaults.yaml`. Tests read actual defaults or use synthetic descriptors.
  Verify default index/platform digests against official registries; distinguish
  digest integrity from verified signatures/provenance. Repository/tag overrides
  clear inherited pins unless their own digest is supplied.

Test ordinary production Puppet code without requiring Empeira-specific branches.
The sole classification exception is `facts.empeira.provider` (`container` or `vm`),
installed and verified before the first catalog. Never expose runtime/backend facts
or generalize this classification API.

## Configuration

Project-bound commands resolve the canonical Git root through the execution runner
and require `.empeira.yaml` there. Empty markers use defaults; invocation from
subdirectories works. Help, version and self-update are project-independent.

Precedence: built-in defaults, project configuration, optional user preferences,
then explicitly allowed CLI overrides. Safe YAML parsing, duplicate-key rejection,
fragment/effective validation and full-path errors apply to every source. Arrays
replace, mappings deep-merge. The schema has an explicit version and logical
namespaces; add keys only for concrete features. Nodes are imperative CLI resources;
never define named nodes or `node_defaults.provider` in YAML.

`~/.empeira.yaml` permits only `runtime.container_engine` and `images.registry`.
Resolve it through the platform home abstraction. Reject all other paths. Registry
authentication belongs to Docker/Podman: no YAML credentials, interactive prompts,
copied auth files or Empeira credential store. Distinguish auth, missing-image,
network and TLS failures; probable auth failures give the resolved native login
command with sanitized diagnostics.

## Bootstrap and secrets

Never expose passwords, tokens, Authorization headers, private keys, certificate
private material, repository/registry/proxy credentials or other secrets in logs,
arguments, inventories, fingerprints or image layers. Keep private files outside
control code with appropriate modes. EYAML keys are server-only read-only mounts.

Agent installation uses a reviewed signed APT/DNF repository or HTTPS package
artifact with mandatory SHA-256. Credentials use only
`EMPEIRA_AGENT_REPO_USERNAME` and `EMPEIRA_AGENT_REPO_PASSWORD`. APT, DNF and curl
read credentials from temporary 0600 files, never argv. Reject preexisting release
packages before mutation and remove only packages introduced by that transaction.
Authenticated DNF release-RPM sources are unsupported; use a scoped signed custom
DNF repository. Do not reject software combinations by comparing major versions.

Restore and verify original package-manager configuration and remove bootstrap
access and temporary credentials after success/failure, before enrollment/Puppet.
Unverifiable cleanup leaves the node incomplete. Mark provisioned only after
cleanup, final network/configuration and enrollment succeed. Retain incomplete
nodes for diagnostics; block start and Puppet operations until recreated.
A failed catalog on a provisioned node remains retryable. Bootstrap semantics are
provider-independent; Cloud-Init is VM-specific and not required in containers.
Remote bootstrap content requires integrity protection if implemented.

## Network and access

Empeira Network is a logical isolated peer domain shared by container and VM nodes.
Backends must preserve naming, arbitrary internal TCP/UDP, CoreDNS, Puppet and
proxy reachability. Fail closed when capabilities or observed isolation are
unverifiable. Do not assume CLI host/engine filesystem or network equivalence.

Normal operations must not require interactive sudo/root. One-time host setup may
need privileges. Keep helpers narrow, owned and documented. Never give nodes
unrestricted host-network/Internet access or silently fall back to rootful Podman.
Only the workspace gateway and fixed browser UI relay may attach externally.
Gateway policy is default-drop, uses complete destination IPv4/TCP-port grants and
must fail closed during reconciliation. Peer adapters attach nodes but do not own
destination policy. Never flush host/engine firewall tables or modify foreign rules.

Normal proxy access uses `proxy.enabled`, with the union of `proxy.global` and every
matching `proxy.rules[].allow`. Match normalized full hostnames using `*`/`?` globs.
All workspace nodes are clients when enabled; destinations remain allowlisted.
Preserve private/metadata-address denial and HTTP/HTTPS-only behavior. Authenticated,
source-bound bootstrap access is separate and temporary. DNS uses host/corporate
resolvers with no hard-coded public fallback. Internal names remain authoritative;
an optional additional resolver falls through on NXDOMAIN/NODATA.

The shared lab is cooperative, not an adversarial tenant boundary. PuppetDB HTTP
is unauthenticated inside the isolated network, never host-published. Normal
agent/server/CA TLS remains intact; global autosigning is disabled.

`node shell` is direct runtime exec or a private VM serial console. `node ssh` is
real SSH using the local username and normal OpenSSH identities/agent/config, with
independent `--user`/`--identity`. Authentication failure never injects users/keys
or falls back to shell. Verify owned endpoints and use private node known-hosts.
VM management credentials are separate. Console password applies once, is redacted
and removed from temporary seed material, never restored after Puppet changes it.
Private console sockets support macOS path limits and are removed with the node.

Browser traffic stays isolated; publish only its fixed TLS UI destination on a
dynamic loopback port. The browser command reconciles only that pair and requires
existing infrastructure. Additional services share ownership, DNS and fingerprints,
with no general ports/volumes/devices/capabilities/privileged/runtime-option schema.
Generated service YAML is plain, literal, atomic and read-only; reject unsafe or
overlapping paths and tags/aliases. Avoid application-specific orchestration.

## Persistent state and lifecycle

Before infrastructure mutation, validate the project release requirement through
`BuildInfo`, then take the shared nonblocking workspace lock. Read-only status
uses no exclusive lock. Keep the lock inode stable; never delete it as recovery.
Development builds cannot verify explicit release requirements. Absent/null
requirements allow development; infrastructure never updates Empeira automatically.

Versioned, atomic external inventory records owning runtime, logical identities,
observed IDs, intent and definitions. Invalid/unreadable state fails closed. Runtime
observations establish existence; inventory establishes ownership/recovery context.
Persist intent before creation and inspect uncertain outcomes before retry/cleanup.
Verify labels and recorded IDs before deletion; names alone are insufficient.
Never force-delete an attached network, adopt foreign resources, silently migrate
runtimes or initialize missing retained storage/credentials as empty data.

Node names are reserved atomically across providers in the same transaction.
Stop preserves state; start resumes; destroy removes owned resources/certificates
and releases identity. `down` removes services/networks while retaining storage;
`destroy` removes owned nodes, CA and database data without redundant prompts.
Both preserve control code, modules and caches.

Canonical SHA-256 definition/component fingerprints exclude unrelated config,
application versions, secrets and observed addresses. Reconcile only safe affected
services, preserving storage/nodes. Network changes and database migrations require
explicit operations. Unsupported alpha schemas fail closed without implicit upgrades.

Server-only host mounts are structured, read-only by default and overlap-checked;
verify canonical source visibility through the runtime. Hiera mounts use standard
Puppet module/environment paths, remain live/read-only and are optional unless
required. Environment-cache invalidation uses authenticated semantic APIs.
Command mocks use the existing generated files, inventory and lock, not parallel state.

## Update plane

`self-update` updates Empeira only; `update images` and `update modules` are explicit
artifact operations; `update all` includes every target and fails before mutation
when a required target is unavailable. Do not implement package replacement or
hidden continuation flags without a concrete packaging handoff design.

Updates share the version gate/lock but never require infrastructure inventory,
networks or services. Disposable owned helpers use the runtime default bridge,
minimal mounts and observed-membership verification; remove them after success,
failure or interruption when the engine is reachable. Host Git uses normal user
SSH/configuration; never copy keys or credentials into helpers/images/state.

`up` acquires missing images only, performs no freshness checks and never
synchronizes Puppetfile modules. Missing modules fail before mutation. Explicit
module updates reuse host mirrors/native r10k caches and write directly into
`modules.path`; no generations, tree hashes or implicit Puppet runs. Image updates
use bounded native metadata checks and refresh changed artifacts with native cache;
no fallback pull after metadata failure or unconditional `--no-cache`. Select the
default and workspace-used node variants. Preserve existing node/VM revisions.
Progress counts real completed modules/artifacts and keeps successful tool logs quiet.

## Testing and completion

Use deterministic isolated RSpec with synthetic data. No production infrastructure,
credentials, certificates, keys or proprietary artifacts. Share behavioral provider
contracts. Before completing changes, run the complete RSpec suite, RuboCop and
both lockfile dependency audits with current advisories; check documentation and
Bash completion when CLI behavior changes. Run relevant real provider/integration
gates when capabilities exist. Report unavailable checks precisely; never claim
unexecuted runtime, VM, remote CI or publishing checks as successful.

Normal quality CI runs deterministic RSpec on Ubuntu with Ruby 3.4 and 4.0.
RuboCop and both bundler-audit checks run only on Ruby 3.4; release builds use Ruby 3.4.
A focused Docker/OpenVox PR smoke runs the existing real node test. Broader runtime,
browser, network and VM suites are manual; VM gates require capable self-hosted
runners. Avoid automatic heavy matrices and schedules. Linux/macOS/WSL2 validation
must reflect actual execution; native Windows Ruby is not a substitute.

Bash completion is part of the CLI contract. Update commands, options, providers,
OS versions and node candidates with CLI changes. Keep shell-specific presentation
separate so future shells can use core completion data without runtime probing.

## Commits and releases

Local work stays on the checked-out branch unless requested otherwise. Remote
work uses the explicitly designated integration base and task branches; never
infer `main` merely because it exists. Honor task-specific push/PR/release limits.
Commit successfully validated work automatically in logical Conventional Commits,
after reviewing every change for scope, documentation and accidental content.
Do not commit unexpected test failures. Report created commits and actual checks.

Use `feat`, `fix`, `perf` and `refactor` for public functional changes; use `docs`,
`test`, `chore`, `ci`, `build` and `style` for the corresponding internal work.
GitHub release tags are the authoritative released version; `BuildInfo` supplies
version, revision and build time without requiring Git at runtime. No independent
manual version file. Release artifacts contain only reviewed project files.

The release workflow is manual, validates the designated `main` revision and runs
quality/E2E gates before publishing a Gem. Only the publishing job has write access;
prereleases use explicit alpha/beta/rc tags. GitHub native notes classify merged PRs
by labels in `.github/release.yml`; Conventional Commits remain the commit convention.
Do not promise unavailable distributions or publish proprietary third-party assets.
