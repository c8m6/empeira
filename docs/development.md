# Development

## Environment and quality checks

Install Git, Ruby 3.4, Bundler and the platform prerequisites in
[installation](installation.md). The gem requires Ruby 3.4+; Ruby 3.2 and 3.3 are
unsupported. Normal Ubuntu CI runs deterministic RSpec on Ruby 3.4 and 4.0, with
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

For workflow changes, parse `.github/workflows/*.yml` and run `actionlint` when
available. Review action pins, triggers and permissions as well as YAML syntax.
See [contributing](../CONTRIBUTING.md) for review, commit and label conventions.

### Ruby 4.0 compatibility

Ruby 3.4 and 4.0 are supported. The deterministic suite passed locally on Linux
x86_64 with Ruby 3.4.7 and 4.0.7. Ruby 4.0 validation used an official Ruby container;
it does not establish macOS, container-engine or accelerated VM integration results.

Source development uses Bundler 4.0.22 from `Gemfile.lock`, matching the existing
module-helper tooling. With Ruby 4.0.7, the previous Bundler 2.4.19 redefined
`Gem::Platform` constants and emitted warnings in child processes. This failed 14
strict stderr, streaming, Bash completion and Puppetfile installer tests. Updating
Bundler preserves those output assertions; no application output filtering or
warning suppression is used. The dependency gem versions are unchanged.

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
| `vm` | Accelerated VM lifecycle and proxy policy |
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

The real VM lifecycle regression verifies the default managed SSH login and explicit
overrides, then exercises retained disk and console recovery. A second case injects
a permanent guest error at the final APT backup removal: the restored archive must
remain verifiable, Puppet must stay blocked, and SSH/console access must release the
workspace lock while preventing concurrent stop of that instance. The injected error
does not reproduce an unexplained historical SSH disconnect.

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
The first distribution is a GitHub-attached Ruby gem; RubyGems.org publication,
standalone Linux/macOS binaries and automatic self-update are not implemented.

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
