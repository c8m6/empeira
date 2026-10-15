# Development

## Environment and quality checks

Install Git, Ruby 3.1+, Bundler and the platform prerequisites in
[installation](installation.md). The gem requires Ruby 3.1+; normal Ubuntu CI
runs deterministic RSpec on Ruby 3.1, 3.2, 3.3, 3.4 and 4.0, with
RuboCop and both dependency audits only on Ruby 3.4. Release builds use Ruby 3.4.
Use synthetic control repositories and disposable credentials.

```console
bundle install
bundle exec rspec
bundle exec rubocop
bundle exec bundler-audit check --update
bundle exec bundler-audit check --gemfile-lock resources/modules/Gemfile.lock
```

`bundle exec rake` also runs RSpec. Normal tests use isolated temporary projects,
local child processes and loopback fixtures. Explicit integration gates are pending
unless enabled; a pending test is not a successful runtime check. Security auditing
covers known Ruby advisories in both resolutions, not all container OS packages.
To reproduce either CI test job, activate the corresponding Ruby, install the locked
bundle and run `bundle exec rspec --exclude-pattern 'spec/integration/**/*_spec.rb'`.
Runtime and VM compatibility remain separate manual gates.

Addon tests (`spec/addon_*_spec.rb`) use the existing loopback Git fixture,
concurrent CLI subprocesses, a real PTY and the generated Bash completion. They
exercise branches, tags and commit refs without external Git services or container
startup. The complete `spec/fixtures/addon` is also the documented minimal addon.
When extending configuration, review `Schema::ADDON_PRIVATE_PATHS`: secret fields
and opaque content require explicit exclusion from the addon environment API.

Runtime proxy regression coverage runs real guest helpers against isolated fake
guest roots, checks foreign APT/DNF ownership, and exercises privileged VM command
environment separately from bootstrap. Never execute these helpers against the
developer's `/etc` in unit tests.

`spec/interactive_tools_spec.rb` executes native Bash against synthetic startup
files, covering login/non-login behavior, PATH preservation, duplicate prevention
and ownership failures. The manual runtime management gate also checks installed
agent commands on retained guests after restart.

The manual runtime management gate checks real VirtIO execution while Puppet sets
root shadow to `!`, replaces sudoers, removes the regular `empeira` account and
changes, restarts and disables system SSH. It verifies subsequent `node puppet`,
retry after exits 4/6, user SSH without the management endpoint, verified upload
cleanup, stop/start, interface facts and normal proxy reconciliation. The gate
combines a thin disk, first-catalog dummy/VLAN facts and normal proxy package
installation. `spec/vm_guest_spec.rb` covers streaming, full output, native status,
interruption, binary upload and operation identity against isolated Unix peers.
`spec/vm_guest_agent_spec.rb` runs the guest adapter against a synthetic private
transport and temporary files; its simulated numeric-UID boundary is not a real
root-lock test. `spec/vm_runtime_spec.rb` verifies ownership and QEMU endpoints.
`spec/vm_system_account_spec.rb` checks one-time regular account preparation with
synthetic passwd/shadow data. Run real gates with available runtime and acceleration:

```bash
EMPEIRA_RUNTIME_MANAGEMENT_INTEGRATION=1 EMPEIRA_VM_RUNTIME=docker \
  EMPEIRA_RUNTIME_MANAGEMENT_PROVIDERS=vm \
  bundle exec rspec spec/integration/node_runtime_management_spec.rb
```

Add `--example 'after Puppet locks root'` for the dedicated account-independent
management and user SSH acceptance scenario. The fixture uses persistent guest
files, disables the automatic Puppet service through ordinary Puppet resources,
and waits for completed user sessions to disappear before deleting their account.
The CLI agent runs remain real and include native exits 4/6 and retry.

Select `container` and `EMPEIRA_VM_RUNTIME=podman` for the corresponding rootless
Podman package/PATH/reconciliation gate. These remain manual, capability-dependent
tests rather than additions to the automatic heavy CI matrix.
For available Rocky Linux images, `EMPEIRA_DNF_RUNTIME_INTEGRATION=1` enables
`spec/integration/node_dnf_proxy_spec.rb` for containers and accelerated VMs. It
installs through a Puppet-owned additional signed repository while retaining the
original sources, then verifies restart and proxy disable/enable reconciliation.
The gate defaults to Rocky 9; set `EMPEIRA_DNF_GUEST_VERSION=8` to exercise Rocky 8.

Network regression gates exercise both node providers through their production
transports. The DNS gate checks live rewrite reloads without replacing nodes or
DNS. The redirect gate checks payload preservation, flow revocation and refusal
of external fallback under both runtimes. Run them on a capable local host:

```bash
EMPEIRA_DNS_NODE_INTEGRATION=1 EMPEIRA_VM_RUNTIME=docker \
  bundle exec rspec spec/integration/dns_rewrites_nodes_spec.rb
EMPEIRA_INTEGRATION=direct-egress EMPEIRA_REDIRECT_VM=1 \
  EMPEIRA_REQUIRED_RUNTIMES=docker,podman \
  bundle exec rspec spec/integration/network_redirects_spec.rb
```

For workflow changes, parse `.github/workflows/*.yml` and run `actionlint` when
available. Review action pins, triggers and permissions as well as YAML syntax.
See [contributing](../CONTRIBUTING.md) for review, commit and label conventions.

### Ruby compatibility

Ruby 3.1, 3.2, 3.3, 3.4 and 4.0 are tested by the deterministic Ubuntu CI matrix.
This does not establish native macOS, container-engine or accelerated VM
integration results for every Ruby version. Integration and release builds remain
on Ruby 3.4.

Source development and the module-helper use Bundler 2.6.9 for Ruby 3.x,
which supports the Ruby 3.1 minimum. Ruby 4 CI upgrades to Bundler 4.0.22
and changes only the `BUNDLED WITH` entries in both lockfiles before testing,
preventing RubyGems platform-constant warnings from contaminating subprocess
output. To replicate Ruby 4 CI locally, install Bundler 4.0.22, change both
lockfile Bundler versions to 4.0.22, and run `bundle _4.0.22_ install`. The r10k transitive dependency `fast_gettext` is constrained
to the Ruby-3.1-compatible 3.1 series instead of 4.x (which requires Ruby 3.2),
and `multi_json` is pinned to 1.18.0 instead of 1.21.x (which also needs 3.2).
The existing gem versions are otherwise retained. Run tests under each Ruby
version after installing the locked bundle; do not infer compatibility from a
successful syntax-only check.

The test checkout must be writable: the QEMU monitor-directory cleanup fixture
uses the checkout as a synthetic home. A read-only container bind mount caused one
additional filesystem failure; the compatibility run uses a writable disposable
copy. This fixture does not launch QEMU or establish real VM compatibility.

## Real runtime tests

Docker needs a reachable Linux engine 28+ with isolated bridge and helper support.
Podman needs rootless Netavark; cgroup v2 is required for enforced limits and systemd
nodes. Bind mounts must be visible at canonical host paths. Runtime tests pull public
images and need sufficient memory, disk space and registry/package access. Chromium
requires substantially more storage than the standard OpenVox smoke.

Run one explicit scope and runtime through the existing test driver:

```bash
EMPEIRA_TEST_SCOPE=containers EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec ruby script/integration.rb
EMPEIRA_TEST_SCOPE=services EMPEIRA_REQUIRED_RUNTIMES=podman \
  bundle exec ruby script/integration.rb
```

| Scope | Existing suites / behavior |
| --- | --- |
| `containers` | Runtime contracts and real Ubuntu/RPM node lifecycle |
| `services` | Control plane, exported resources, proxy policy, OpenVox View and generated service YAML |
| `nodes` | Default OpenVox lifecycle and signed DNF installation |
| `network` | Gateway allow/deny/revocation and transparent TCP redirects from a managed container and Puppet server; Docker also exercises DNS resolvers/rewrites |
| `images` | Native metadata, immutable pins, reconciliation and synthetic registry authentication |
| `lifecycle` | Isolated runtime smoke, Hiera/EYAML, SSH, ownership and cleanup |
| `mounts` | Read-only/writable server mounts and selective reconciliation |
| `development` | Environment caching, live code and package bootstrap |
| `node-tools` | Diagnostic tools and agent-free node recipes |
| `modules` | Synthetic Git/r10k synchronization, live mounts and offline reuse |
| `update-plane` | Disposable helpers, artifact refresh and public Forge acquisition without infrastructure |
| `browser` | Real Chromium UI, internal reachability and isolation |
| `vm` | Accelerated VM lifecycle, proxy policy and dummy/VLAN interface reconciliation |
| `redirect-nodes` | TCP redirects from existing container/accelerated VM nodes and Puppet server; preserved HTTP bytes, target recreation, connection revocation and external canary |
| `dns-nodes` | DNS rewrite reload/removal with real container and accelerated VM nodes |
| `shared-network` | Production container/VM TCP/UDP peer lifecycle |
| `full` | All listed container scopes; excludes VM/dns-nodes/redirect-nodes/shared-network |

The `Manual runtime integration` workflow exposes these scopes through
`workflow_dispatch`. It selects one engine and has no automatic or scheduled heavy
run. A required unavailable runtime fails instead of becoming a successful skip.
Public-source outages and registry rate limits remain real validation failures.

The focused Squid regression uses a synthetic HTTP/HTTPS server on an isolated
private RFC 1918 subnet. Allowed and denied domains resolve to the same address;
the test checks domain allowlists, hostname rules, proxy reconciliation and blocked
direct egress for both engines:

```bash
EMPEIRA_INTEGRATION=1 EMPEIRA_REQUIRED_RUNTIMES=docker,podman \
  bundle exec rspec spec/integration/control_plane_spec.rb --example 'allows selected'
```

The automatic PR workflow runs the existing Ubuntu default node lifecycle test:

```bash
EMPEIRA_INTEGRATION=1 EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec rspec spec/integration/node_spec.rb \
  --example 'docker runs the default OpenVox node' --format documentation
```

It creates a temporary Git control repository with an empty `.empeira.yaml`, applies
a real Hiera-backed file resource, verifies default agent installation and CA
signing, checks a second run returns zero changes, and waits for the actual catalog
and changed/unchanged reports in PuppetDB. It also exercises state retention, live
edits, certificate cleanup/reuse and CA recreation. Failure diagnostics are bounded
and sanitized. Cleanup runs after failures and verifies that workspace-labeled
containers, networks and volumes are absent. No global prune is used.
The workflow reads all software pins from `config/defaults.yaml`; it needs no
repository secrets and uses public artifacts only.

Before the PR smoke, its disposable hosted Docker daemon uses Google's public
[Docker Hub cache](https://docs.cloud.google.com/artifact-registry/docs/pull-cached-dockerhub-images)
at `mirror.gcr.io`. Setup preserves existing daemon settings and verifies the active
mirror after restart. This also covers Docker Hub base images used by local builds;
GHCR images keep their original source. Image references, configured digest pins,
TLS verification and the complete smoke assertions remain unchanged. Cache hits
avoid the shared runner's anonymous Docker Hub pull quota. Cache misses still use
Docker Hub, and acquisition failures remain failures. The public-only smoke uses a
private, empty `DOCKER_CONFIG` directory instead of inheriting runner registry
credentials. Failures include bounded, sanitized Docker daemon diagnostics so a
failed mirror and canonical-registry fallback remain visible. Local engines and
workspace DNS, gateway and isolation policy are unaffected by this CI-only setup.

The APT authentication regression uses a local HTTPS repository with synthetic Basic
credentials and an ephemeral GPG signing key. It checks the helper's effective
`auth.conf.d` configuration, private file mode and exact credential bytes, then
verifies metadata returns 401 before one interactive login and 200 after the retry.
The selected package download must reuse that login and pass its SHA-256 check.
It requires host `gpg`/`gpgconf` and a locally reachable container engine; helper and
host TLS verification remain enabled. Run it explicitly for either engine:

```bash
EMPEIRA_INTEGRATION=agent-auth EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec rspec spec/integration/agent_repository_auth_spec.rb --example docker
EMPEIRA_INTEGRATION=agent-auth EMPEIRA_REQUIRED_RUNTIMES=podman \
  bundle exec rspec spec/integration/agent_repository_auth_spec.rb --example podman
```

Lightweight CI runs deterministic RSpec excluding `spec/integration`, RuboCop and
both dependency audits. Both quality and PR smoke support `main` and `initial`
during the transition; no branch migration is performed by a workflow.

## VM and shared-network prerequisites

Use real KVM on Linux/WSL2 or HVF on macOS, QEMU, `qemu-img`, `xorriso`, OpenSSH and
any required firmware. Preflight runs before image/cache or runtime mutation.
Rootless Podman also needs writable TUN/KVM inside its namespace. See
[VM installation](installation.md#vm-prerequisites) and
[networking](networking.md#runtime-attachment-and-privilege-boundary).

The VM scope also includes `spec/integration/vm_interfaces_spec.rb`. It observes real
Linux dummy/VLAN types, VLAN IDs, addresses and activation, checks Facter JSON, and
reads a file written by the first catalog from the ordinary network bindings. It
creates the VM with both a 32 GiB disk and interface rules, verifies the thin overlay,
unchanged base checksum and root filesystem growth, and checks package installation.
Later interface edits and removal use `vm.disk: 48` while retaining the original
32 GiB capacity through reconciliation and restart. The deterministic VM provider
regressions verify root growth precedes packages and interfaces, and that failed
growth blocks both features, enrollment and Puppet.
The real gate also tests idempotent `up`, stop/start restoration, address/VLAN edits and removal,
with managed SSH, DNS, proxy, gateway redirects and Puppet TLS checks. This gate
requires the same capable disposable host; deterministic guest models do not prove
real kernel or Facter compatibility.

The real VM lifecycle regression verifies the default managed SSH login and explicit
overrides, then exercises retained disk and console recovery. A second case injects
a permanent guest error at the final APT backup removal: the restored archive must
remain verifiable, Puppet must stay blocked, and SSH/console access must release the
workspace lock while preventing concurrent stop of that instance. The injected error
does not reproduce an unexplained historical SSH disconnect.
The lifecycle case also verifies a 32 GiB thin overlay, unchanged base checksum,
grown root partition/filesystem, package installation and `df -h /`. After changing
`vm.disk` to 48 GiB, workspace reconciliation and restart must retain the 32 GiB disk.
The VM lifecycle and container `lifecycle` smoke also load personal SSH defaults
before creating nodes. They exercise hostname rules, `~/` identity expansion,
independent CLI overrides and the unchanged internal bootstrap/Puppet transports.

```bash
EMPEIRA_VM_INTEGRATION=1 EMPEIRA_VM_RUNTIME=docker \
  bundle exec rspec spec/integration/vm_spec.rb --format documentation
```

```bash
EMPEIRA_TEST_SCOPE=vm EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec ruby script/integration.rb
EMPEIRA_TEST_SCOPE=shared-network EMPEIRA_REQUIRED_RUNTIMES=podman \
  bundle exec ruby script/integration.rb
```

GitHub VM scopes require a dedicated disposable self-hosted Linux/AMD64 runner
labeled `empeira-vm`, with the selected runtime and acceleration already configured.
Ordinary GitHub-hosted runners are not assumed to have KVM/HVF. Use only trusted
manual revisions on that runner; do not expose it to fork PR code. A macOS/HVF
host runs the same local gates separately. Report Linux/WSL2, macOS, amd64 and
arm64 execution independently.

The lower-level regression proofs remain opt-in:

```bash
EMPEIRA_SHARED_NETWORK=1 bundle exec rspec spec/integration/shared_network_spec.rb
EMPEIRA_MACOS_NETWORK=podman bundle exec rspec spec/integration/macos_shared_network_spec.rb
EMPEIRA_MACOS_NETWORK=docker bundle exec rspec spec/integration/macos_shared_network_spec.rb
EMPEIRA_SHARED_GUEST_CHECK=1 bundle exec rspec spec/integration/shared_guest_artifact_spec.rb
```

The last command is an explicit TCG test-artifact diagnostic, not evidence of
accelerated product VM support. These proofs do not substitute for the production
peer lifecycle gate. Test arbitrary TCP/UDP between providers, internal browser
reachability, DNS, egress revocation, unchanged node identities and owned cleanup.

The network scope includes real transparent redirect tests for both runtimes.
The accelerated scope adds a managed QEMU VM to the same traffic assertions:

```bash
EMPEIRA_TEST_SCOPE=redirect-nodes EMPEIRA_REQUIRED_RUNTIMES=docker bundle exec ruby script/integration.rb
EMPEIRA_TEST_SCOPE=redirect-nodes EMPEIRA_REQUIRED_RUNTIMES=podman bundle exec ruby script/integration.rb
```

It verifies DELETE/path/Host/custom header/body and a complete 64 KiB response,
same-service hairpin connections, changed source/target ports, multiple sources,
owned target recreation at a different IP, unchanged node/service identities,
preserved connections on identical `up`, revoked established connections on removal,
and zero requests to an external canary even with an overlapping egress grant.
This manual scope requires KVM/HVF preflight and is excluded from `full` and normal CI.

The Docker network scope includes real CoreDNS tests for exact DNS rewrites:

```sh
EMPEIRA_INTEGRATION=1 EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec rspec spec/integration/dns_rewrites_spec.rb
EMPEIRA_TEST_SCOPE=dns-nodes EMPEIRA_REQUIRED_RUNTIMES=docker \
  bundle exec ruby script/integration.rb
```

The first gate uses isolated CoreDNS and DNS-client containers to check A/AAAA/CNAME
answers, dynamic service addresses, exact matching, reload/removal and no external
fallback. The manual `dns-nodes` scope additionally requires accelerated QEMU and
tests both real container and VM nodes across repeated `up` without restarting
them. It is deliberately separate from ordinary CI and container-only `full`.

## Build information and releases

GitHub tags are the released-version authority. `BuildInfo` embeds version, revision
and UTC build time without requiring Git at runtime. Source checkouts report
`development`; the gem packaging fallback is `0.0.0.development`.

The manual release workflow accepts `tag`, `channel` (`alpha`, `beta`, `rc`, `stable`)
and `dry_run` (default true). Dispatch it from `main`; a prerelease tag must match
its channel, for example `v0.1.0-alpha.1`. Other branches and existing tags/releases
are rejected. Quality and real Docker/OpenVox gates must pass before the build.

The build uses the existing `rake build_info` task in a temporary source staging
directory, builds an installable gem, and checks its contents, license, normalized
Gem version and exact embedded metadata. RubyGems normalizes a tag such as
`v0.1.0-alpha.1` to gem version `0.1.0.pre.alpha.1`; CLI BuildInfo retains
`0.1.0-alpha.1`. No source version file or generated commit is maintained.

Test the build locally without creating tags or contacting GitHub:

```bash
EMPEIRA_BUILD_VERSION=v0.1.0-alpha.1 \
EMPEIRA_RELEASE_CHANNEL=alpha \
EMPEIRA_BUILD_REVISION=0123456789abcdef0123456789abcdef01234567 \
EMPEIRA_BUILD_TIME=2026-01-01T00:00:00Z \
  bundle exec ruby script/release.rb build
```

The result is in ignored `pkg/`. Source `lib/empeira/build.json` is untouched.
The lower-level task also supports `rake 'build_info[OUTPUT_PATH]'`; without that
argument it writes the ignored source metadata. Remove source metadata to return
that checkout to development mode.

For publishing, only the final job gets `contents: write`. It downloads the exact
built gem, checks its checksum and metadata, confirms the selected revision is still
`main`, creates the tag atomically and prepares a draft release with its asset and
[GitHub native release notes](https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes).
It verifies the draft's tag revision, release channel and sole uploaded gem's name,
size and SHA-256 before publishing. A final API read verifies the published state
and the same tag/asset; missing assets, a retained draft or an API error fail the run.
Alpha/beta/rc are prereleases and do not become latest stable.
Dry-run performs all quality/build gates but skips the entire publishing job.

### Release failure and recovery

Tag creation and GitHub release publication are separate operations. A failed run
can leave a tag with no visible release, an incomplete draft, or an already published
release when the final verification failed. None of these states is treated as a
successful workflow run. Validation reports an existing draft/published **GitHub
release** first; an existing **tag** without a visible release gets a separate
diagnostic. A read token may not see a retained draft, so maintainers must inspect
both the release list and the failed run with write access.

1. Inspect the failed publishing step, the tag's commit, draft/published state and
   attached assets. Compare the tag with the tested revision and the gem with the
   build job's checksum and embedded BuildInfo. Workflow artifacts are retained for
   seven days; do not substitute an unverified rebuild.
2. For a tag without a release or an incomplete draft, a maintainer may manually
   complete the original publication at that exact tested revision using the verified
   artifact and native release notes. Verify all assets before publishing the draft.
   If the original artifact or validation evidence is unavailable, choose a new version.
3. If publication already happened, inspect and verify the remote release instead
   of retrying publication. An incorrect or incomplete published release requires a
   corrected release under a new version. A failed verification does not prove that
   publication was rolled back.

The workflow never resumes an existing tag/release, deletes tags, moves tags or
reuses published version names. Rerunning it with the same retained tag is rejected;
another workflow run requires a new unused version. Manual recovery does not turn
the original failed run green.

With [GitHub Immutable Releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
enabled, published assets cannot be added, replaced or deleted, and the associated
tag cannot be moved or deleted while the release exists. Even deleting that release
does not permit reuse of its tag name. Drafts remain editable until publication;
the workflow therefore uploads and verifies the entire asset set before publishing.
Title and release-note edits do not repair incorrect immutable assets.

Release notes use merged PR labels from `.github/release.yml`, independently of
Conventional Commit types. See [label conventions](../CONTRIBUTING.md#release-note-labels).
The first alpha is distributed as a verified GitHub Release gem and published
unchanged to [RubyGems.org](https://rubygems.org/gems/empeira) via OIDC Trusted
Publishing. Standalone Linux/macOS binaries and automatic self-update are not
implemented.

### RubyGems.org distribution (manual)

After a verified GitHub Release exists, use
`.github/workflows/publish-rubygems.yml` via **Actions → Publish existing release to RubyGems.org → Run workflow**.
Run it from `main`, entering the existing release tag (for example `v0.1.0-alpha.1`).
The default `dry_run: true` checks the existing GitHub release, tag ancestry,
uploaded gem SHA-256 and embedded build metadata; it never creates a tag,
rebuilds a gem or contacts RubyGems with publishing credentials.

For a new gem that has not yet been published, the owner must first configure a
[Pending Trusted Publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers)
on RubyGems.org. Empeira's publisher is already configured for gem `empeira`,
repository owner `c8m6`, repository `empeira`, workflow filename
`publish-rubygems.yml` and no GitHub Environment. After a successful dry-run,
run the same workflow with `dry_run: false`. Only its upload step receives
short-lived RubyGems credentials via GitHub OIDC; no persistent API key is required.

Publishing uploads the exact previously verified GitHub Release asset, not a
second build, and does not modify GitHub Releases or source. It fails closed
if the asset differs, the tag is not on `main`, or RubyGems rejects the upload.
RubyGems does not allow uploading the same gem name/version twice; inspect
the existing published version before rerunning a failed push. After success,
install the alpha with `gem install empeira --pre`. GitHub Releases remain
the authoritative archive of release artifacts.

## Dependency and image provenance

Thor is the sole application runtime gem. Development tools and the isolated r10k
installer are separate dependency resolutions. Dependencies are not vendored into
the release gem. Check upstream licensing and advisories before upgrades:

- [Thor](https://rubygems.org/gems/thor), [RSpec](https://rubygems.org/gems/rspec),
  [RuboCop](https://rubygems.org/gems/rubocop), [Rake](https://rubygems.org/gems/rake)
  and [Bundler](https://rubygems.org/gems/bundler): MIT.
- [bundler-audit](https://github.com/rubysec/bundler-audit): GPL-3.0-or-later development tool.
- [r10k](https://github.com/puppetlabs/r10k) and
  [puppet_forge](https://github.com/puppetlabs/forge-ruby): Apache-2.0; reviewed versions
  and checksums are in `resources/modules/Gemfile.lock`. Log4r's packaged
  `doc/content/license.html` supplies permissive Ruby-style terms.
- The official [Go builder](https://github.com/docker-library/golang) uses BSD-style
  Go licensing; its notice is retained in the adapter image. The adapter uses only
  the standard library. Go is not a host prerequisite and no compiled adapter is bundled.
- GitHub-owned checkout/upload/download actions and ruby/setup-ruby are pinned by
  commit; their MIT notices stay upstream. No action code is copied into the project.

Preserve package/image notices in locally built helpers. Registry pins establish
artifact integrity, not a universal signature or vulnerability guarantee.
See [image provenance](configuration.md#control-plane-images-and-provenance) and
[node image provenance](nodes.md#node-images-and-fidelity) for component sources.

The private adapter uses Python 3 already supplied by the reviewed cloud images;
it introduces no Python packages or guest-agent package bootstrap dependency.
QEMU Guest Agent was evaluated: its `guest-exec-status` returns captured output
only after exit, may report truncation and offers no command cancellation API.
The owned VirtIO adapter provides immediate streaming and process-group cleanup.
See the [QGA protocol reference](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html).

Run `EMPEIRA_INTEGRATION=server-environment bundle exec rspec spec/integration/server_environment_spec.rb`
to check native timeout 0, live edits, CA retention, PuppetDB and idempotent up
under Docker/rootless Podman with the default server and a custom entrypoint
that ignores timeout environment mapping.
The same gate verifies startup and idempotent `up` with an explicit
`environment.conf` timeout override, preserving the file and distinguishing its
effective value from the native server setting.

Run the isolated diagnostics/recovery gate with each native runtime:

```sh
EMPEIRA_DIAGNOSTIC_INTEGRATION=1 EMPEIRA_DIAGNOSTIC_RUNTIME=docker bundle exec rspec spec/integration/node_diagnostics_spec.rb
EMPEIRA_DIAGNOSTIC_INTEGRATION=1 EMPEIRA_DIAGNOSTIC_RUNTIME=podman bundle exec rspec spec/integration/node_diagnostics_spec.rb
```

Both runs include container and QEMU/KVM nodes; select either with
`EMPEIRA_DIAGNOSTIC_PROVIDERS=container` or `vm` when the other is unavailable.
The VM gate requires acceleration and exercises root locked by Puppet, disabled
SSHD, separated exec streams, exact exits, timeouts, concurrent VirtIO sessions,
real PTY resize/job control/fullscreen output and terminal restoration, restart,
serial console without the guest service, and cleanup after removal of the server
and control repository with an incompatible inventory. Projects and resources
are disposable and isolated; production infrastructure is never used.

## DNS endpoint, node identity and Hiera selection gates

These opt-in gates use disposable synthetic control repositories and owned helpers.
The DNS upstream is synthetic; no production DNS server is needed. The identity
gate requires working KVM/HVF and checks Ubuntu containers and VMs, multi-component
FQDNs, native Facter values, certnames, restart, legacy fact upgrades and an actual
first catalog using shared/provider Hiera data. Physical host files are checked for
changes. Run both container engines where available:

```bash
EMPEIRA_HIERA_SELECTION_INTEGRATION=1 EMPEIRA_HIERA_SELECTION_RUNTIME=docker bundle exec rspec spec/integration/hiera_selection_spec.rb
EMPEIRA_DNS_REDIRECT_INTEGRATION=1 EMPEIRA_DNS_REDIRECT_RUNTIME=docker bundle exec rspec spec/integration/dns_redirects_spec.rb
EMPEIRA_NODE_IDENTITY_INTEGRATION=1 EMPEIRA_NODE_IDENTITY_RUNTIME=docker bundle exec rspec spec/integration/node_identity_spec.rb
```

Repeat with `podman`. Hiera selection uses the configured server image, including
priority/merge lookups and a negative production-node fixture with no Empeira fact.
The DNS gate checks UDP/TCP, internal/external names, NXDOMAIN, large-answer fallback,
unavailable/recreated CoreDNS, a second workspace with a different subnet and
CoreDNS address, rule removal and idempotent reconciliation. Node identity also
checks both virtual DNS transports before and after node stop/start.
