# Proxy policy

Normal external HTTP/HTTPS access stays behind Squid. Enabling the workspace proxy
makes it available to every node; global and hostname rules remain the destination
allowlist:

```yaml
proxy:
  enabled: true
  global:
    - forgeapi.puppet.com
  rules:
    - hosts: ["lab-*"]
      allow: ["*.github.com"]
    - hosts: ["*-web-*"]
      allow: [github.com, nginx.org]
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

Defaults are `proxy.global: []` and `proxy.rules: []`. Every node receives
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
denied. There is no TLS interception. Server-side outbound traffic gets
`proxy.global` only; node hostname rules do not expand server access.

## Node policy and reconciliation

When `proxy.enabled` is true, all nodes are authorized as proxy clients. Nodes get
upper/lowercase proxy variables and internal `NO_PROXY` entries, including explicitly
configured `network.egress` hosts. Those named hosts use the common workspace
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

## Managed bootstrap

Managed bootstrap destinations are separate from normal user policy. Reviewed
agent and distribution endpoints in `agent.install` and `bootstrap.guests` allow
Puppet/OpenVox and required guest packages to be installed without duplicating them
in `proxy.global`. The temporary authenticated bootstrap proxy uses workspace DNS
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
