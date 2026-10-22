# Proxy policy

Normal external HTTP/HTTPS access stays behind Squid. Nodes and infrastructure
have independent switches and destination lists, both disabled by default. Enabling
the node scope makes its global and hostname rules available to nodes:

```yaml
proxy:
  nodes:
    enabled: true
    global:
      - forgeapi.puppet.com
    rules:
      - hosts: ["lab-*"]
        allow: ["*.github.com"]
      - hosts: ["*-web-*"]
        allow: [github.com, nginx.org]
  infrastructure:
    enabled: false
    allow: []
```

```console
empeira up
empeira node run lab-web-1-01.example.net --provider container
empeira proxy show lab-web-1-01.example.net
```

The diagnostic prints:

```text
Effective proxy policy for lab-web-1-01.example.net
All workspace nodes may use this policy after 'empeira up' reconciles the proxy.
Global:
  forgeapi.puppet.com
Matched rules:
  lab-*
  *-web-*
Allowed:
  forgeapi.puppet.com
  *.github.com
  github.com
  nginx.org
Managed bootstrap destinations are separate from this normal policy.
```

The diagnostic resolves desired policy even for a hostname that does not exist.
It reports when the normal proxy is disabled and does not claim that live
infrastructure has already been reconciled.

## Matching and destinations

Defaults are `proxy.nodes.global: []` and `proxy.nodes.rules: []`. Every node receives
all global destinations plus `allow` from **every** matching rule. Duplicate entries
are removed while preserving configuration order. A rule matches when any of its
`hosts` patterns matches the complete lowercase hostname. Patterns must be lowercase.
`*` matches any sequence, including dots, and `?` matches one character. Examples
include `*-web-*`, `lab-*` and `*-db-??.*`. There is no regex, first-match,
last-match or deny-rule syntax. Container and VM providers use the same resolver.

Destination rules are separate from hostname globs:

| Entry | Meaning |
| --- | --- |
| `github.com` | Exact DNS destination |
| `*.github.com` | Squid domain family, including the apex and its subdomains |
| `https://github.com`, `github.com/path`, `github.com:443` | Invalid |
| IP literals, whitespace, internal Empeira names | Invalid |

Only HTTP port 80 and HTTPS CONNECT port 443 are allowed. Allowed DNS destinations
are reachable regardless of their target IP range, including private, loopback,
link-local and reserved addresses. Domains without a matching allow rule remain
denied. There is no TLS interception. Node destinations never grant infrastructure
access, and infrastructure destinations never grant node access.

## Node policy and reconciliation

When `proxy.nodes.enabled` is true, all nodes are authorized as proxy clients. Nodes get
upper/lowercase proxy variables and internal `NO_PROXY` entries, including explicitly
configured `network.egress.nodes` hosts. Those named hosts use the common workspace
gateway for their configured ports. VM access uses the same destination policy bound
directly to the VM instance's reserved peer address. The proxy is reached at
`proxy.empeira.internal:3128` on the isolated network. A request without a matching
global or hostname rule remains denied.

After changing global destinations or rules, or updating Empeira's generated Squid
policy, run `empeira up`. It regenerates current node bindings and reloads Squid
after readiness without replacing the proxy or unrelated services. Unchanged
policy and bindings do not trigger a reload. A checkpoint in the existing
inventory records the proxy ID and digest of the small configuration files only
after the native reload succeeds; a failed or interrupted reload is retried by
the next `up` even when files already contain the requested policy.
Container and VM nodes consume the new policy without a restart; open proxy
connections can end during reconciliation. Enabling/disabling proxy mode is a
separate topology change and may require explicit node cleanup as reported by `up`.

Changing `network.egress.infrastructure` destinations also changes infrastructure
`NO_PROXY`. Changing node destinations does not change the server environment. `up` replaces a server whose environment definition changes while
retaining CA storage and node identities. Changing only destination ports or
transparent redirect rules preserves the server when its definition is unchanged.

## Infrastructure policy

`proxy.infrastructure.enabled` controls the Puppet/OpenVox server, PostgreSQL,
PuppetDB backend/relay and `containers.additional` services. Its independent
`allow` list uses the same exact-domain and domain-family syntax as node grants.
The browser, DNS, Squid and gateway transports do not receive these application
proxy settings.

```yaml
proxy:
  infrastructure:
    enabled: true
    allow: [api.example.net]
```

When disabled, infrastructure definitions contain empty proxy values, overriding
any image defaults. They contain no configured proxy endpoint and receive no Squid
client grants, even if the node proxy is enabled. No startup wrapper removes an
otherwise configured proxy. Internal names and mocks remain directly reachable.
When enabled, only infrastructure's own direct destinations enter its `NO_PROXY`.
Explicit environment settings in additional-service definitions remain application
configuration; they do not add Squid permissions.

`up` creates the shared normal proxy when either scope is enabled and removes it
when both are disabled. Changing infrastructure's switch updates affected service
definitions while retaining storage and node identities. Allowlist-only edits reload
Squid without replacing unrelated services. Direct grants remain independent of
both proxy switches; keep `network.egress.infrastructure: []` for internal-only
infrastructure.

## Migrating shared settings

The former `proxy.enabled`, `proxy.global` and `proxy.rules` keys are rejected with
a migration diagnostic. Move them under `proxy.nodes`; configure infrastructure
explicitly with its own switch and `allow` list. Old shared `network.egress` arrays
and legacy `mode` values are also rejected. Move grants to `network.egress.nodes`
or `network.egress.infrastructure` according to the intended clients. No existing
grant is silently copied to infrastructure.

## Managed bootstrap

Managed bootstrap destinations are separate from normal user policy. Reviewed
agent and distribution endpoints in `agent.install` and `bootstrap.guests` allow
Puppet/OpenVox and required guest packages to be installed without duplicating them
in `proxy.nodes.global`. The temporary authenticated bootstrap proxy uses workspace DNS
and retains its private, loopback, link-local and reserved destination-address
restrictions independently of normal proxy policy. Its credential is not stored in
the guest seed, JSON inventory or logs. A /32 source ACL admits only the provisioning
node. The proxy and its private configuration are removed after use. When the normal
workspace proxy is disabled, a node has no proxy access once bootstrap ends.

`bootstrap.guests.*.destinations` grants network access only; it never writes an APT
source. Ubuntu and Debian retain the base image's sources. The temporary agent
repository and every other `/etc/apt` change made during bootstrap are restored and
verified before the proxy is removed and before Puppet starts. The reviewed Ubuntu
defaults permit archive/security only for amd64 and ports only
for arm64.

Default OpenVox sources include `apt.voxpupuli.org` and
`yum.voxpupuli.org`; distribution mirrors come from reviewed base images.
Custom agent sources are configured under `agent.install` and are not embedded
in Empeira. Their versions, checksums and destination lists are user-managed.
Package managers verify repository signatures. See the
[official OpenVox installation sources](https://voxpupuli.org/openvox/install/),
[Ubuntu archives](https://archive.ubuntu.com/ubuntu/) and
[Rocky repositories](https://dl.rockylinux.org/pub/rocky/).

For later package updates performed by Puppet, enable the normal proxy and add the required
destinations to global or matching normal rules. They can remain permitted
permanently. Requests to all other destinations remain denied.

Puppetfile synchronization and image refreshes belong to the independent update
plane. They do not use this workspace proxy or its allowlists. Forge runs in a
disposable helper with normal container-runtime networking and supplied user proxy
variables. Git uses the invoking user's host Git/SSH configuration and network
access, without copying private keys. No update starts Squid, CoreDNS or other
workspace services. See [update-plane architecture](architecture.md#runtime-and-update-planes).
Self-update and the aggregate `update all` remain unavailable.
