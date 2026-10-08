# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/c8m6/empeira/security/advisories/new)
when it is available and enabled for this repository. A GitHub account is
required. Open the repository's **Security** tab and select
**Report a vulnerability**.

If that option is unavailable, including while the repository is private, open
an issue asking only for a private security contact. Do not include vulnerability
details, affected sensitive endpoints, exploit instructions or attachments in
that issue. Wait until a private channel has been agreed before sharing details.
No email address or alternative private channel is published here.

Do not use public GitHub Issues or pull requests to disclose an exploitable,
undisclosed vulnerability. Keep reproduction details in the private report until
disclosure has been coordinated with the maintainers.

Include the affected release tag or commit, deployment conditions, required
permissions, expected and observed behavior, and a minimal reproduction using
synthetic data. Describe the potential impact. Do not include production private
keys, passwords, tokens, certificates containing sensitive information, or other
secrets.

## Versions and fixes

The project does not currently publish a maintained-version matrix, a long-term
support policy or a guaranteed response schedule. This document does not promise
security backports to older releases. Report the exact affected version even if
you cannot reproduce the issue on the newest release.

Check [GitHub Releases](https://github.com/c8m6/empeira/releases) for release and
prerelease status and update notes. Release tags are the authoritative
application version source.

## Security scope and development

Empeira is a disposable local Puppet/OpenVox development and testing environment.
Network isolation, workspace ownership, credentials and host/guest boundaries
are relevant to security reports. Describe the host platform, container runtime,
node provider and configuration using synthetic examples.

The shared workspace is a cooperative disposable lab, not an adversarial tenant
boundary. Its internal PuppetDB API is unauthenticated; never publish it outside
the lab or use production secrets there. Runtime administrators and privileged
peers are trusted within that boundary.

Fork PR checks have read-only repository permissions and need no repository
secrets. Releases are manual and limited to reviewed `main` revisions after quality
and real OpenVox checks. Use only trusted revisions on manual self-hosted VM runners.

Never include production control code, EYAML private keys, registry or proxy
credentials, certificate private keys or proprietary Puppet Enterprise files.

See [development and validation](docs/development.md) and
[networking](docs/networking.md) for current procedures and isolation behavior.
A passing automated check does not prove that no vulnerabilities remain.
