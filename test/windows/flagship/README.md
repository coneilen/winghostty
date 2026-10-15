# Flagship verification contracts

Versioned, machine-readable contracts for the flagship runtime rewrite.

- `scenario.schema.json`: stable scenario definition format.
- `result.schema.json`: runner output consumed by CI and baseline comparisons.
- `baseline-manifest.schema.json`: checksummed frozen-oracle inventory.
- `scenarios/`: workflow-runnable scenario definitions.
- `examples/`: format examples; hashes are placeholders, not frozen evidence.
- `baselines/`: immutable manifests tied to a base commit and verified hashes.

Validate the contracts:

```powershell
pwsh -File test/windows/flagship/Test-VerificationContracts.ps1
```

Hosted Windows CI runs the x64 portable smoke through
`Invoke-PortableSmoke.ps1`. The GUI composite is opt-in: manually dispatch the
`Test` workflow with `run_interactive_win11` set to `true` to run it on an unlocked
self-hosted runner labeled `Windows`, `X64`, and `winghostty-interactive`.
Pushes, pull requests, and nightly schedules do not queue work on that runner.
The job fails unless the runner is Windows 11 x64, non-system, attached to the
active console session with an Explorer shell, on the `Default` input desktop,
and checked out at the exact workflow SHA. Its name, user, session, exact
commit, workflow run, and machine are persisted as a provenance artifact. This
narrows accidental runner drift; the self-hosted machine remains an explicit CI
trust boundary and must be registered ephemerally for release validation.

Nightly hosted CI retains local release-copy consistency checks. The inherited
remote latest-release check runs only in `amanthanvi/winghostty`, the publisher
hardcoded by `scripts/check-release-copy.ps1`; this fork does not track that
publisher's moving latest release and has no published latest release of its own.
Before enabling remote release verification here, migrate the release-copy
sources and checker to this fork's release channel together.

The daily `Clean Artifacts` workflow grants `actions: write` only to its cleanup
job so it can delete old artifacts; `contents: read` allows its tagged-run checks.
