# Installation

Empeira runs natively on Linux and macOS. Windows uses **WSL2 → Linux → Empeira**;
native Windows Ruby is unsupported. The gemspec requires **Ruby >= 3.4**; the
supported Ruby versions are **3.4 and 4.0**. Normal CI tests both on Ubuntu;
release gems are built with Ruby 3.4. Use source installation until a release gem
is available. No RubyGems.org publication is assumed.

## Linux and WSL2

These commands target **Ubuntu 24.04 LTS** and **Debian 13 trixie**. Their default
Ruby packages are below Empeira's minimum; Ruby 3.2 and 3.3 are unsupported.
Install Ruby 3.4+ with your established Ruby version manager before using Empeira.
Ubuntu 22.04 and Debian 12 also need a newer Ruby. Installing the distribution's
default `ruby` package does not satisfy the gemspec on these hosts.

Core/source development dependencies and SSH access:

```bash
sudo apt-get update
sudo apt-get install -y git build-essential openssh-client iproute2
# Activate Ruby 3.4+ using your Ruby version manager before continuing.
gem install bundler
ruby --version
gem --version
bundle --version
git --version
ssh -V
```

The selected Ruby installation must supply `gem` and matching development headers;
`gem install bundler` supplies `bundle`. `build-essential` builds native development
gems; additional Ruby build prerequisites depend on your version manager.
`openssh-client` supplies `ssh`, `ssh-keygen` and `scp` for node SSH and VM management. `iproute2` supplies
host route inspection for automatic workspace subnet allocation. Coreutils supplies
`tail` for VM logs; Bash supplies optional completion. Both are standard on these
hosts. Downloads use Ruby libraries; Empeira does not invoke host curl/wget.

Default runtime (Podman with Netavark):

```bash
sudo apt-get install -y podman netavark
podman --version
podman info --format '{{.Host.NetworkBackend}}'
```

The backend must be `netavark`. Run Empeira as your normal user with rootless
Podman; do not mix rootful and rootless inventories.

Docker alternative: use **Docker Engine >= 28** with the Linux bridge driver.
Ubuntu 24.04's and Debian 13's distribution `docker.io` packages are too old for isolated gateway mode.
The following uses Docker's official apt repository on Ubuntu or Debian; it
assumes conflicting distribution Docker packages have already been removed as
specified by the upstream guide:

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/$ID/gpg" | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
  "$(dpkg --print-architecture)" "$ID" "${UBUNTU_CODENAME:-$VERSION_CODENAME}" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
# Start a new login session before continuing. Docker group access controls the engine.
docker --version
```

Set `runtime.container_engine: docker` in `.empeira.yaml`, or use
`--container-engine docker`. WSL2 can instead use Docker Desktop's WSL integration
with a Linux engine >= 28; do not install a competing daemon in that distribution.

### VM prerequisites

Optional packages, only for VM users:

```bash
# amd64 host:
sudo apt-get install -y qemu-system-x86 qemu-utils xorriso openssh-client
qemu-system-x86_64 --version

# arm64 host instead:
sudo apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils xorriso openssh-client
qemu-system-aarch64 --version

# Both architectures:
qemu-img --version
xorriso -version
ssh -V
```

`qemu-utils` supplies `qemu-img`. AArch64 requires the `qemu-efi-aarch64` firmware;
x86_64 uses QEMU's default firmware. Linux VM creation requires usable KVM:

```bash
ls -l /dev/kvm
id
# If /dev/kvm belongs to group kvm and your account lacks access:
sudo usermod -aG kvm "$USER"
```

Start a new login session after a group change. The device must exist, permit
read/write access and support the KVM API; group membership alone is insufficient.
Empeira reports ioctl failures and never silently falls back to TCG.

### WSL2 specifics

Use the Linux commands above inside an Ubuntu 24.04 or Debian 13 WSL2 distribution,
with source/control checkouts on its Linux filesystem. KVM is unnecessary for
container-only use. VM use requires `/dev/kvm` and functional nested virtualization;
check `ls -l /dev/kvm` and apply the group/access remediation above if appropriate.
After group changes, run this **from Windows PowerShell**, then reopen WSL:

```powershell
wsl --shutdown
```

A missing KVM device requires a compatible Windows/WSL kernel and virtualization
configuration; adding a group cannot create acceleration. WSL mirrored networking
is not a prerequisite. Windows-host QEMU/WHPX is not currently implemented.

## macOS with Homebrew

Install Homebrew using its [official instructions](https://brew.sh/), then core:

```bash
brew install git ruby@3.4 openssh
export PATH="$(brew --prefix ruby@3.4)/bin:$PATH"
gem install --user-install bundler
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
ruby --version
gem --version
bundle --version
git --version
ssh -V
```

Keep those PATH settings in your shell configuration if desired. Apple’s system
Ruby is not suitable. Ruby 3.4 is the recommended development version. macOS supplies `scutil` for host/split DNS discovery and `tail` for logs.

Default runtime:

```bash
brew install podman
podman machine init
podman machine start
podman --version
```

Podman runs Linux containers in its managed Linux VM. Run `machine init` only once.
The engine must use Netavark and see the control repository and Empeira state bind
mounts. Configure machine sharing for paths outside its normal shared directories.

Docker alternative:

```bash
brew install --cask docker-desktop
open -a Docker
docker --version
```

Wait for Docker Desktop to start, use its Linux engine >= 28, and select Docker in
Empeira configuration. Docker Desktop has its own distribution/license terms; it
is not bundled with Empeira. The CLI host and engine must agree on mount paths.

Optional VM tools:

```bash
brew install qemu xorriso
qemu-img --version
xorriso -version
# Apple Silicon:
qemu-system-aarch64 --version
qemu-system-aarch64 -accel help
# Intel instead:
qemu-system-x86_64 --version
qemu-system-x86_64 -accel help
```

Homebrew QEMU provides its firmware. **HVF** is the expected accelerator; Empeira
fails if unavailable. Real macOS/HVF VM E2E, macOS container engine integration,
and arm64 browser/runtime E2E remain separate manual gates. Lightweight CI does
not establish those results. See the [VM validation gates](development.md#vm-and-shared-network-prerequisites).

## Source installation and project opt-in

```bash
git clone https://github.com/c8m6/empeira.git
cd empeira
bundle config set --local path vendor/bundle
bundle install
export EMPEIRA_SOURCE="$PWD"
empeira() { BUNDLE_GEMFILE="$EMPEIRA_SOURCE/Gemfile" bundle exec ruby "$EMPEIRA_SOURCE/bin/empeira" "$@"; }
empeira --version
empeira help
cd ../control-repo
touch .empeira.yaml
empeira config validate
empeira update modules   # only when the project uses a Puppetfile
empeira up
empeira browser
```

The control repository must already be a Git repository. Project commands resolve
`git rev-parse --show-toplevel` through the execution runner and require an actual
`.empeira.yaml` at that canonical root. An empty file uses defaults. Subdirectory
invocation and paths with spaces work. No Puppet-file heuristic or `--project`
selector exists. The source shell function preserves the current directory.
Version/help/self-update work outside Git (self-update currently reports unavailable).

## Release gem installation

Download the `.gem` asset from a [GitHub release](https://github.com/c8m6/empeira/releases)
when one is available, then install it with your existing Ruby environment:

```bash
gem install --user-install ./empeira-VERSION.gem
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
empeira --version
```

Replace `VERSION` with the downloaded asset's filename. RubyGems installs the Thor
runtime dependency; no third-party agents, images or binaries are bundled. The
release version is embedded in BuildInfo. Standalone binaries and automatic
self-update are unavailable. Do not use `sudo gem install` for normal operation.

For other Linux distributions, install equivalent Ruby/Git/runtime packages through
your established host setup. Guest OS support does not imply a tested host recipe.
Report native Linux, WSL2, macOS and runtime/architecture validation separately.

## Bash completion

For an installed executable or the source function above in Bash:

```bash
source <(empeira completion bash)
```

Completion includes browser, additional lifecycle commands, node names from
inventory, configured OS versions, providers and runtime values. Both spaced and
`--provider=con` forms work, including Bash's split `=` tokens. Project-dependent
completion uses the current Git repository and returns no project candidates outside
one. It never probes a runtime. No shell configuration is changed automatically.

## Installation references

Upstream installation references:
[Ubuntu noble indexes](https://archive.ubuntu.com/ubuntu/dists/noble/),
[Debian trixie index](https://deb.debian.org/debian/dists/trixie/main/),
[Docker Ubuntu](https://docs.docker.com/engine/install/ubuntu/),
[Docker Debian](https://docs.docker.com/engine/install/debian/),
[Homebrew Ruby 3.4](https://formulae.brew.sh/formula/ruby@3.4),
[Podman](https://formulae.brew.sh/formula/podman),
[QEMU](https://formulae.brew.sh/formula/qemu),
[xorriso](https://formulae.brew.sh/formula/xorriso),
[OpenSSH](https://formulae.brew.sh/formula/openssh),
[Docker Desktop](https://formulae.brew.sh/cask/docker-desktop).

### Peer networking prerequisites

Linux/WSL2 subnet allocation requires iproute2 even for container-only use.
Native rootless Podman VM networking also requires Netavark,
user namespaces, `/dev/net/tun`, and KVM access inside the rootless namespace:

```bash
podman --remote=false unshare --rootless-netns test -w /dev/net/tun
podman --remote=false unshare --rootless-netns test -w /dev/kvm
```

Normal operation does not use sudo. Device/ACL setup is an administrator's one-time
host task. Linux Docker uses the owned packet-helper model and requires its engine
to support `/dev/net/tun` and `NET_ADMIN` for that helper. macOS uses QEMU/HVF plus
rootless Podman Machine or Docker Desktop, with the canonical state directory
shared where needed. The runtime builds the packaged static adapter; **Go is not
a normal Empeira prerequisite**. IPv4 is the supported peer protocol initially.
