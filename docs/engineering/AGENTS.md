# Shared engineering guidelines

Use these defaults in projects that adopt them. Follow the repository and
directory instructions for the files you change. Their specific contracts,
commands and release procedures take precedence over these defaults. An explicit
task instruction can narrow or override a convention for that task.

## Interfaces and naming

- Read a typical call, command or configuration example before settling on a
  public interface. A caller should be able to tell what it does, which inputs
  it needs and what result to expect.
- Use the project's domain vocabulary. Name a parameter for its role. Give
  operations with the same meaning consistent names, argument order, return
  values and failure behavior. For example, `expires_at` and `expires_in_seconds`
  distinguish a timestamp from a duration at the point of use.
- Make side effects visible. A lookup should be safe to repeat. Give an
  operation that creates, replaces or deletes data a name that says so.

## Implementation and failure handling

- Trace the affected behavior from its entry point to the component that owns
  it. Make the smallest change that fixes the cause across supported callers.
  Keep unrelated cleanup out of a bug fix.
- Give each component a clear responsibility. Reuse the existing owner of a
  rule, default or state transition. Introduce an abstraction when it removes
  a concrete source of drift or isolates a dependency that needs testing.
- Preserve existing contracts, including stored data and configuration. When
  the task changes a contract, cover its migration or compatibility behavior.
- Validate external input at the boundary. Report the failed operation and
  the underlying cause when known. Redact sensitive values before emitting
  diagnostics. For operations that can partially succeed, establish what
  happened before retrying or cleaning up.
- Preserve license and attribution notices. Before adding third-party code,
  assets or dependencies, check provenance, license compatibility and, for
  dependencies, maintenance and known vulnerabilities. Surface unresolved risks.

## Verification and handoff

- For a bug fix, exercise the failing behavior through a supported entry point.
  Add a regression case when existing coverage misses it. Use isolated,
  synthetic test data and control external dependencies for deterministic tests.
- Review existing documentation with every change. Update affected instructions
  and examples in the same logical commit unless there is a clear reason to
  separate them. Preserve literal user-facing labels and configuration keys.
- Run the checks required by the repository. Fix unexpected failures introduced
  by the change before committing. Report which checks passed, failed or could
  not run, with the specific reason for each gap.
- Review the diff for scope and accidental changes. Keep each commit focused
  on one independently reviewable and revertible outcome. Follow the project's
  commit, branch and publication conventions.

The interface guidance draws on the language-independent naming and clarity
principles in the [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
