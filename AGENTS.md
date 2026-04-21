# AGENTS

## Recovery Start Point

For recovery-harness work, start with these files in order:

1. [docs/recovery/HANDOFF.md](docs/recovery/HANDOFF.md)
2. [docs/recovery/scenario-implementation-roadmap.md](docs/recovery/scenario-implementation-roadmap.md)
3. [docs/recovery/scenarios/README.md](docs/recovery/scenarios/README.md)
4. the specific scenario file being worked on

If the change touches shared contracts, also read:

- [docs/recovery/harness-spec.md](docs/recovery/harness-spec.md)
- [docs/recovery/source-fixture-spec.md](docs/recovery/source-fixture-spec.md)
- [docs/recovery/rewrite-tool-spec.md](docs/recovery/rewrite-tool-spec.md)

## Recovery Workflow Rules

- Treat [docs/recovery/scenario-implementation-roadmap.md](docs/recovery/scenario-implementation-roadmap.md) as the current execution order and status source. Individual scenario specs may lag behind reality.
- Before implementing any scenario, do a spec pass first. Capture or refresh the scenario's exact:
  - preconditions and dependencies
  - snapshot label or fixture profile
  - manifest inputs and expected outputs
  - automation entrypoints and scripts to add or change
  - assertions, evidence sources, and report artifacts
  - timing windows, tolerated nondeterminism, and cleanup rules
  - fault-injection and rollback steps for negative cases
- Prefer a test-first loop:
  - write the first failing test at the lowest useful layer
  - implement the smallest change that makes it pass
  - rerun tests, then container or end-to-end checks
  - only then move to the next slice
- Prefer a dedicated Git worktree per scenario implementation slice so docs, harness changes, and run artifacts stay isolated while the scenario is in flight.
- When running from a fresh worktree, assume generated fixtures are absent unless proven otherwise. If the worktree does not contain `fixtures/snapshots/<label>`, set `SNAPSHOTS_ROOT` to the shared snapshot directory before `automation/recovery/prepare`.
- Shared harness paths may be overridden explicitly through `FIXTURES_ROOT`, `DOCS_ROOT`, `SOURCE_LIVE_ROOT`, `SOURCE_ARTIFACTS_ROOT`, `SNAPSHOTS_ROOT`, `SCENARIO_RUNS_ROOT`, and `REPORT_RUNS_ROOT`. Use those instead of hard-coding repo-root-relative paths in new scripts.
- Do not add host dependencies beyond Docker and basic shell tooling. Use repo-managed Docker images, wrappers, or Testcontainers instead.
- Keep exec sessions short-lived. Avoid accumulating idle PTYs.
- Do not trust a reused recovery workdir after a failed boot. Re-run `prepare` and `rewrite`, or rebuild the scenario run directory, before the next `up`.
- Never revert unrelated worktree changes.

## Current Resume Point

- Scenario 01 is green on run `20260421T084355Z`.
- Scenario 02 is green on run `20260421T095313Z`.
- Scenario 05 is green on run `20260421T113800Z`.
- The next implementation target is Scenario 08.
