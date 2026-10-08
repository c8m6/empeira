# Contributing to Empeira

Contributions and pull requests are welcome. Develop changes on a branch, keep
each commit focused, and use Conventional Commits as described in
[AGENTS.md](AGENTS.md). Search existing issues before reporting a bug or proposing
a feature, and use the repository's issue and pull request templates.

## Licensing

By submitting a contribution, you confirm that you have the right to submit it
and intend it to be distributed as part of Empeira under `AGPL-3.0-only`.
Do not knowingly submit code, documentation, assets, or other material whose
license is incompatible with the project.

Preserve all applicable third-party copyright, attribution, and license notices.
Describe the origin and license of new dependencies or third-party material in
the pull request. Raise uncertain compatibility or provenance for review.

The project does not require a Contributor License Agreement or assignment of
copyright. Contributors retain ownership of their contributions.

## Development and validation

Start with [installation](docs/installation.md) and the
[development guide](docs/development.md). Follow the Ruby/Bundler setup documented
there and run:

```console
bundle exec rspec
bundle exec rubocop
bundle exec bundler-audit check --update
bundle exec bundler-audit check --gemfile-lock resources/modules/Gemfile.lock
```

Review Linux, macOS and WSL2 implications. Native Windows execution is not
supported. Runtime and networking changes require the relevant real Docker,
Podman or VM checks when the required capabilities are available. Use isolated
workspaces, synthetic control code and test credentials; never use production
resources or redistribute proprietary Puppet Enterprise software.

Keep Empeira focused on disposable Puppet/OpenVox infrastructure. Reuse existing
configuration, execution, provider, ownership and workspace mechanisms. Update
affected documentation and Bash completion when CLI behavior changes.

Report the checks actually run and any unavailable host capabilities or
dependencies. CI limits do not turn unexecuted local or runtime checks into
successful validation.

## Commits and pull requests

Use focused Conventional Commits: `feat`, `fix`, `perf`, `refactor`, `docs`,
`test`, `ci`, `build`, `chore` or `style`. Describe the functional result in the
subject. Include actual validation and any unavailable capabilities in the PR.
Quality CI accepts `main` and `initial`; releases are dispatched from `main` only.
Local automation stays on the checked-out branch and follows explicit task limits
on pushing, pull requests and publishing.

## Release-note labels

GitHub native release notes classify merged pull requests by labels in
[.github/release.yml](.github/release.yml), independently of commit types.
Maintainers should create any missing labels and apply one primary category:

| Label | Category |
| --- | --- |
| `enhancement` or `feature` | Features |
| `bug` | Bug Fixes |
| `performance` | Performance |
| `maintenance`, `refactor` or `dependencies` | Maintenance / Refactoring |
| `documentation` | Documentation |
| No matching label | Other Changes |
| `skip-release-notes` | Excluded from generated notes |

No workflow creates or changes labels automatically. Review PR labels before
dispatching a release. The [development guide](docs/development.md#build-information-and-releases)
describes the manual release and its default dry-run.

## Reporting issues

Include the Empeira version, host platform, runtime and node provider, relevant
image/version information, reproduction steps and sanitized diagnostics. Use
synthetic configuration; omit private keys, EYAML secrets, credentials and
internal endpoints. Do not disclose undisclosed vulnerabilities in public issues.

## Community and security

Follow the [code of conduct](CODE_OF_CONDUCT.md) in project interactions.
Report undisclosed vulnerabilities using [SECURITY.md](SECURITY.md), rather than
posting details in public issues or pull requests.
