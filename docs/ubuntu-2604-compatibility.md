# Ubuntu 26.04 compatibility

Ubuntu 26.04 uses the unified cgroup v2 hierarchy and ships a Rust-based sudo
implementation by default. Neither change requires Empeira to switch its
privileged node-management transport to sudo.

## Current Empeira contract

- Container `node exec` / `node shell` use native runtime execution as UID 0.
- VM bootstrap, agent commands and `node exec` / `node shell` use the
  private VirtIO management channel with UID/GID 0, not system SSH or sudo.
- Interactive `node ssh` exercises the real guest login and has no automatic
  privilege escalation.
- Ubuntu container images add the distribution's `sudo` package for
  **Puppet-managed catalogs**, not for Empeira management. The version and
  implementation installed are distribution-dependent.
- `node_defaults.init: systemd` requires Podman and a cgroup v2 host;
  default `process` mode does not run guest systemd as PID 1.

## Automated scope

`.github/workflows/ubuntu-2604-compat.yml` verifies that the Linux CI host
exposes cgroup v2 and that an Ubuntu 26.04 OCI base can install `sudo` and
`systemd`, execute noninteractive sudo as root, and deny passwordless
privilege escalation to an unconfigured non-root account.

**Limitations:** This is a packaging/security smoke test, **not** an Empeira
end-to-end test. The workflow does not provision an Empeira node, boot systemd
inside a container or run Puppet. In particular, a GitHub-hosted Ubuntu 24.04
runner does not validate Empeira on an Ubuntu 26.04 host.

## Manual integration matrix (dedicated disposable Linux host)

Before declaring Ubuntu 26.04 fully supported, use an Ubuntu 26.04 host with
Podman/Netavark, Docker and QEMU/KVM installed and configured, and a disposable
Git control repository with `.empeira.yaml`. Record runtime versions, architecture,
results, and failures. Verify host cgroup v2:

```sh
stat -fc %T /sys/fs/cgroup # expected: cgroup2fs
podman info --format '{{.Host.NetworkBackend}}' # expected: netavark
```

Execute separately for each case (do not reuse inventory across providers):

| Case | Configuration | Acceptance |
| --- | --- | --- |
| Podman, process | Ubuntu 26.04 container, process init | `up`, `node run`, `node exec -- id -u`, `node shell`, `node puppet`, `destroy` |
| Podman, systemd | Ubuntu 26.04 container, systemd init | Same, plus `systemctl is-system-running` inspection and service operation |
| Docker, process | Ubuntu 26.04 container, process init | Same; systemd init is not asserted for Docker |
| QEMU/KVM VM | Ubuntu 26.04 cloud image with required Python 3 | `up`, `node run`, root `node exec`/`shell`, regular `node ssh`, `node puppet`, `destroy` |

Also apply a representative Puppet catalog that manages `sudo`/`sudoers`
and check the actual sudo behavior inside the guest. Do not treat the
distribution package smoke as proof of sudoers policy compatibility.

If a test fails, capture host/runtime versions, full native failure output,
init mode and OS image digest. Change provider/bootstrap logic only after
identifying a reproducible incompatibility. Do **not** install a classic sudo
implementation merely to make a check pass.
