# Installation

Empeira runs on Linux, macOS and Linux inside WSL2. Native Windows is not supported.

- [Prerequisites](#prerequisites): what Empeira needs on the host
- [Host setup: Linux and WSL2](#host-setup-linux-and-wsl2): Ruby, Git and container engine packages
  - [Podman](#container-engine-podman-default) or [Docker](#container-engine-docker-alternative)
  - [VM prerequisites](#vm-prerequisites) (optional)
  - [WSL2 specifics](#wsl2-specifics)
- [Host setup: macOS](#host-setup-macos): Homebrew packages and container engine
- [**Install Empeira**](#install-empeira): the gem, `PATH` and updates
- [Run from source](#run-from-source): for development and unreleased changes
- [**Starting a project**](#starting-a-project): the first commands in a control repository
- [Bash completion](#bash-completion)
- [Upstream references](#upstream-references): official package and install pages

## Prerequisites

| Requirement | Reason |
| --- | --- |
| Ruby 3.2 or newer (3.2–3.4 and 4.0 are tested) | Empeira is a Ruby gem |
| Git | Every project Empeira is used with must be a git project |
| OpenSSH client | for `empeira node ssh` |
| Podman with Netavark and cgroup v2 (default), **or** Docker Engine 28+ | Runs the Puppet server, PuppetDB and container nodes |
| QEMU, `qemu-img`, xorriso, KVM or HVF (optional) | Only for VM nodes, see [VM prerequisites](#vm-prerequisites) |

Empeira never installs any of these per default. Normal Empeira use never needs `sudo`.
Host setup (installing packages, group membership) may need `sudo` once.

## Host setup: Linux and WSL2

The commands below are for Ubuntu and Debian based distros. On other distributions, a different package manager has to be used to install the tools.

```bash
sudo apt-get update
sudo apt-get install -y ruby git openssh-client iproute2
ruby --version   # must be 3.2 or newer, 3.1 is not supported
```

`iproute2` lets Empeira find a free subnet for its isolated network.
Debian 12 default ruby is 3.1 and must be upgraded to at least 3.2.

### Container engine: Podman (default)

```bash
sudo apt-get install -y podman netavark
podman info --format '{{.Host.NetworkBackend}}'   # must print: netavark
podman info --format '{{.Host.CgroupsVersion}}'   # must print: v2
```

Empeira uses rootless Podman as your normal user. Netavark is the network backend
it relies on for isolation. cgroup v2 is what lets Podman enforce the memory and
CPU limits Empeira sets on every service, and it is required for
`node_defaults.init: systemd`. Current Ubuntu, Debian, Fedora and Arch-based
distributions use cgroup v2 by default.

### Container engine: Docker (alternative)

Docker Engine 28 or newer also works. It can be installed with Docker's official guide for
[Ubuntu](https://docs.docker.com/engine/install/ubuntu/) or
[Debian](https://docs.docker.com/engine/install/debian/) (The distributions' own
`docker.io` packages can be too outdated). To use Docker, a user must be added to the `docker` group, then a relogin, and adding the following in `~/.empeira.yaml` or `.empeira.yaml`:

```yaml
runtime:
  container_engine: docker
```

or once per command with `--container-engine docker`.

### VM prerequisites

This section can be skipped if only container nodes are used, which is the default.
`empeira node run NAME --provider vm` starts a full virtual machine instead,
for example to test code that needs a real kernel, boot process or systemd.
The following is needed for VMs:

```bash
# x86_64 host:
sudo apt-get install -y qemu-system-x86 qemu-utils xorriso
# arm64 host:
sudo apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils xorriso
```

| Tool | Used for |
| --- | --- |
| `qemu-system-*` | Runs the VM (arm64 also needs the `qemu-efi-aarch64` firmware) |
| `qemu-img` (from `qemu-utils`) | Creates each node's disk on top of the cached base image |
| `xorriso` | Builds the cloud-init seed image that configures the VM on first boot |

VMs require hardware acceleration (KVM); Empeira fails instead of falling back to
slow emulation. It should be checked that the user can use `/dev/kvm`:

```bash
ls -l /dev/kvm
sudo usermod -aG kvm "$USER"   # to add access; then relogin
```

With rootless Podman, VMs join the same isolated network as container nodes.
That requires access to `/dev/net/tun` and `/dev/kvm` inside Podman's rootless
network namespace. Both commands must succeed:

```bash
podman --remote=false unshare --rootless-netns test -w /dev/net/tun
podman --remote=false unshare --rootless-netns test -w /dev/kvm
```

With Docker, the engine must support `/dev/net/tun` and the `NET_ADMIN`
capability for Empeira's small network helper container. Only IPv4 is supported.

### WSL2 specifics

Use the Linux steps above inside an Ubuntu or Debian WSL2 distribution
and keep your repositories on its Linux filesystem. Container nodes work without
KVM. VM nodes need `/dev/kvm` from nested virtualization. After a group change,
run `wsl --shutdown` from Windows PowerShell and reopen WSL.

## Host setup: macOS

[Homebrew](https://brew.sh/) needs to be installed, then:

```bash
brew install git ruby@3.4 openssh
export PATH="$(brew --prefix ruby@3.4)/bin:$PATH"   # add to ~/.zshrc
```

Apple's system Ruby is outdated and should not be used. Container engine (Podman is the default):

```bash
brew install podman
podman machine init    # once
podman machine start
```

Podman runs containers in its own Linux VM. That VM must be able to see the
control repository; repositories in the home directory are shared by default.
Docker Desktop with a Linux engine 28 or newer works as well; select it as shown
in [Docker (alternative)](#container-engine-docker-alternative).

For VM nodes, `brew install qemu xorriso` is needed. macOS uses Apple's HVF
acceleration; Empeira fails if it is unavailable.

## Install Empeira

```bash
gem install --user-install empeira --pre
```

`--pre` is needed while Empeira is only published as prerelease versions. To
install an exact version, add for example `--version 0.1.0.pre.alpha.9`. Do not
use `sudo gem install` for normal user installation.

`--user-install` puts the `empeira` command in the gem user directory, which is
usually not in `PATH`. Adding it once to the shell startup file
(`~/.bashrc` for Bash, `~/.zshrc` for Zsh):

```bash
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
```

The directory depends on the Ruby version, so this line asks Ruby for it each time
instead of hard-coding it. If Ruby is managed with a version manager such as
rbenv, the gem commands should already be in `PATH`: then
drop `--user-install` and skip this step.

The Version can be checked with:

```bash
empeira --version
```

To update the gem installation, `empeira self-update` can be used.

The same gem is also attached to each
[GitHub release](https://github.com/c8m6/empeira/releases); these can be installed
 with `gem install --user-install ./empeira-<version>.gem`.

## Run from source

For development or unreleased changes, Empeira can be run from a Git checkout. This
needs Bundler and a C build toolchain for native gems.

```bash
git clone https://github.com/c8m6/empeira.git
cd empeira
bundle config set --local path vendor/bundle
bundle install
```

Add a shell function to `~/.bashrc` or `~/.zshrc`, with the path to the checkout:

```bash
export EMPEIRA_SOURCE="$HOME/src/empeira"
empeira() { BUNDLE_GEMFILE="$EMPEIRA_SOURCE/Gemfile" bundle exec ruby "$EMPEIRA_SOURCE/bin/empeira" "$@"; }
```

The function takes precedence over an installed gem. It needs to be removed before switching
back to the gem. `self-update` does not work for source checkouts; use `git pull`
and `bundle install`.

## Starting a project

An Empeira project is a Git repository with a `.empeira.yaml` file at its root.
An empty file uses the defaults:

```bash
cd control-repo
touch .empeira.yaml
empeira config validate
empeira update modules   # only if the repository has a Puppetfile
empeira up
```

Commands work from any subdirectory of the repository.

## Bash completion

```bash
source <(empeira completion bash)
```

This line can be added to `~/.bashrc`. It completes commands, options, providers,
OS versions and node names.

## Upstream references

Official sources for the packages and installers used above:

- Linux packages: [Ubuntu 24.04 (noble)](https://archive.ubuntu.com/ubuntu/dists/noble/),
  [Debian 13 (trixie)](https://deb.debian.org/debian/dists/trixie/main/)
- Docker Engine: [Ubuntu](https://docs.docker.com/engine/install/ubuntu/),
  [Debian](https://docs.docker.com/engine/install/debian/)
- Homebrew: [Ruby 3.4](https://formulae.brew.sh/formula/ruby@3.4),
  [Podman](https://formulae.brew.sh/formula/podman),
  [QEMU](https://formulae.brew.sh/formula/qemu),
  [xorriso](https://formulae.brew.sh/formula/xorriso),
  [OpenSSH](https://formulae.brew.sh/formula/openssh),
  [Docker Desktop](https://formulae.brew.sh/cask/docker-desktop)
